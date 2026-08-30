-- Chill mode -- the engine, in Hyprland's own Lua.
--
-- Shipped by the Omarchy plugin io.github.nocstah.omachill and injected into
-- the running compositor by its Service.qml:
--     hyprctl eval 'CHILLMODE_OPTS = {...}; dofile("<plugin dir>/chillmode.lua")'
-- once when the shell starts and again after every `hyprctl reload` (which
-- wipes runtime binds, hooks and rules). Nothing is written into
-- ~/.config/hypr. The file is re-entrant: a second dofile() first tears down
-- what the previous one registered (see chillmode.unload at the bottom).
--
-- Options (all optional) come in through _G.CHILLMODE_OPTS:
--   keybind   "SUPER + SHIFT + C"   toggle key ("" = no key)
--   inset     0.10                  each side pulled in by this much of the window
--   size      0.72                  floater size on a workspace with nothing to copy
--   rounding  14                    corner radius while chilled
--   notify    true                  desktop notification on toggle
--
-- WHAT IT DOES
-- The toggle floats every tiled window on the current workspace IN PLACE --
-- each pulled in 10% on all four sides, so it keeps 80% of its width and
-- height and stays centred where it was -- with softer corners and glass
-- via the "chillmode" tag. Both ride on the tag, so chill mode changes only
-- the windows on the workspace you pressed it on; other desktops are left
-- exactly as they were. The layout is deliberately left alone.
-- Press again and exactly those windows tile back where they were (the
-- chilled rectangles are read back into a dwindle tree and replayed) and the
-- previous look comes back.
-- Windows that were already floating are never touched; a window opened on
-- a chilled workspace floats in as well, sized to the average of the windows
-- already chilled there so it arrives looking like one of them. Moving a
-- window across the chill line converts it either way: chilled onto a tiling
-- workspace tiles, tiled onto a chilled workspace joins the floaters. A window
-- you DRAG in keeps the spot and size you dropped it at; one sent over by a
-- keybind, having no drop point, flocks into the least-crowded gap at the
-- size of the windows already there. The tag is the only state, so a config
-- reload can't lose track of what is chilled.
--
-- Scriptable: hyprctl eval 'chillmode.toggle()'  /  'chillmode.toggle(3)'
-- State for UIs: every toggle emits a Hyprland custom event
--     custom>>chillmode <workspace name> on|off
-- and `chillmode.state()` returns { [workspace name] = count } for the bar.

local OPTS = type(_G.CHILLMODE_OPTS) == "table" and _G.CHILLMODE_OPTS or {}
local TAG = "chillmode"
local ROUNDING = tonumber(OPTS.rounding) or 14
local SIZE = tonumber(OPTS.size) or 0.72 -- fallback floater size (fraction of the work area)
local INSET = tonumber(OPTS.inset) or 0.10 -- chilled windows pull in this much of their own size on EACH side
local KEY = OPTS.keybind == nil and "SUPER + SHIFT + C" or OPTS.keybind
local NOTIFY = OPTS.notify ~= false
local PLACE_DELAY = 60 -- ms to let a workspace move settle before placing a window
-- 20ms is one frame at 60Hz: the window is only ever shown at its re-tiled
-- size for about that long before the drop geometry is replayed, which is
-- short enough not to read as a flash. 300 tries keeps the 6s watch window.
local CHASE_TICK, CHASE_TRIES = 20, 300
local GAP, EDGE = 16, 36 -- flocking: overlap padding, and inset from screen edges
local GRID_X, GRID_Y = 20, 12 -- flocking: candidate grid, 21 x 13 positions
-- Chilled windows are held FULLY OPAQUE at the compositor level, active and
-- inactive alike, and "override" makes that stick even when looknfeel's custom
-- look sets a global inactive_opacity.
--
-- That sounds backwards for a mode whose whole point is glass, but it is what
-- makes the glass show the WALLPAPER instead of the window underneath. There
-- are two different transparencies in play:
--
--   client alpha        a terminal drawing its own background at <1. With
--                       blur on and ignore_opacity off, Hyprland replaces what
--                       is behind those pixels with blurred wallpaper. This is
--                       the good one, and it is where chill mode's look
--                       comes from.
--   compositor opacity  inactive_opacity, or an opacity window rule. This one
--                       composites the raw stack beneath the window, unblurred
--                       — so the moment a chilled window lost focus you could
--                       read the window underneath straight through it.
--
-- Verified 2026-08-26 by screenshotting the same overlap with the top window
-- focused and unfocused: at 0.80 the underlying terminal's text was legible
-- through it. Holding chilled windows at 1.0 leaves only the client alpha, and
-- that resolves to wallpaper.
local OPACITY = "1.0 override 1.0 override"
local GLOBALS_STATE = os.getenv("HOME") .. "/.local/state/hypr-chill-globals"

-- Indexed loops, not ipairs, for anything that comes back from hl.*:
-- omarchy-menu-keybindings dofile()s this config in a sandbox where every
-- unknown hl member resolves to a catch-all stub whose __index returns itself.
-- Lua's ipairs honours __index, so it never sees the nil that would stop it and
-- spins at 100% CPU forever. `#` uses rawlen on that stub and yields 0.
local function has_tag(w)
  local tags = w.tags
  if type(tags) ~= "table" then return false end
  for i = 1, #tags do
    if tags[i] == TAG then return true end
  end
  return false
end

local function xy(v) -- HL.Vec2 / {x,y} / {[1],[2]} → x, y
  if type(v) ~= "table" then return 0, 0 end
  return v.x or v[1] or 0, v.y or v[2] or 0
end

local function on_window(fn, w, opts)
  opts = opts or {}
  opts.window = "address:" .. w.address
  hl.dispatch(fn(opts))
end

-- Work area of a monitor in logical pixels: rotated outputs (transform 1/3)
-- report their native w×h, and the reserved edges hold the bar.
local function work_area(m)
  local rot = (m.transform or 0) % 2 == 1
  local mw = math.floor((rot and m.height or m.width) / (m.scale or 1) + 0.5)
  local mh = math.floor((rot and m.width or m.height) / (m.scale or 1) + 0.5)
  local r = type(m.reserved) == "table" and m.reserved or {}
  local rl, rt = r.left or r[1] or 0, r.top or r[2] or 0
  local rr, rb = r.right or r[3] or 0, r.bottom or r[4] or 0
  return (m.x or 0) + rl, (m.y or 0) + rt, mw - rl - rr, mh - rt - rb
end

local function windows_on(ws, keep) -- mapped windows on ws, optionally filtered
  local out = {}
  for _, w in ipairs(hl.get_windows({ workspace = ws.id })) do
    if w.mapped and (not keep or keep(w)) then out[#out + 1] = w end
  end
  return out
end

local function tiled(w) return not w.floating and w.fullscreen == 0 end
local function chilled(w) return w.floating and has_tag(w) end

local function current_workspace()
  local w = hl.get_active_window()
  if w and w.workspace then return w.workspace end
  local m = hl.get_monitor_at_cursor()
  return m and m.active_workspace
end

local function notify(text)
  if not NOTIFY then return end
  hl.exec_cmd("notify-send -e -t 1500 'Chill mode' '" .. text:gsub("'", "'\\''") .. "'")
end

-- How many OTHER windows are chilled on ws. The window under consideration
-- must not count itself: a chilled window arriving on a bare tiling workspace
-- would otherwise see itself standing there and conclude it had landed
-- somewhere already chilled.
local function chilled_others(ws, self)
  local n = 0
  for _, x in ipairs(windows_on(ws, chilled)) do
    if not self or x.address ~= self.address then n = n + 1 end
  end
  return n
end

-- The size a window joining a chilled workspace should take. Precedence is the
-- original shell config's (chill-sizes.conf): copy the same-class floaters
-- already chilling here, else the unrelated ones, else SIZE of the work area
-- on a workspace with nothing to copy from. Those windows already carry the
-- INSET from when they were chilled, so the mean is inset geometry too and the
-- newcomer needs no inset of its own. Never larger than the work area.
local function chilled_size(others, cls, aw, ah)
  local same = {}
  for _, o in ipairs(others) do
    if cls and o.class == cls then same[#same + 1] = o end
  end
  local ref = #same > 0 and same or others
  if #ref == 0 then return math.floor(aw * SIZE), math.floor(ah * SIZE) end
  local tw, th = 0, 0
  for _, o in ipairs(ref) do
    local sw, sh = xy(o.size)
    tw, th = tw + sw, th + sh
  end
  return math.min(math.floor(tw / #ref + 0.5), aw), math.min(math.floor(th / #ref + 0.5), ah)
end

-- Where an arriving window goes: "mac-ish flocking", ported from the shell
-- config. Grid-search the work area for the least-overlapped spot, ties broken
-- by closeness to the flock — the centroid of the windows already chilling
-- here. Overlap is measured with each neighbour padded by GAP so windows keep
-- breathing room, and candidates are inset EDGE from the screen edges so
-- borders stay visible. Dead centre on an empty workspace.
--
-- Sorting on overlap FIRST and distance second is the whole trick: nearest
-- alone stacks newcomers on the pile, least-overlap alone sends them to the
-- corners (which is what the pre-2026-08-09 version did — it picked the spot
-- farthest from everything and new windows fled the flock).
local function flock_spot(others, fw, fh, ax, ay, aw, ah)
  local ex = math.min(EDGE, math.floor((aw - fw) / 2))
  local ey = math.min(EDGE, math.floor((ah - fh) / 2))
  if #others == 0 then
    return ax + math.floor((aw - fw) / 2), ay + math.floor((ah - fh) / 2)
  end
  local cx, cy = 0, 0
  for _, o in ipairs(others) do
    local ox, oy = xy(o.at)
    local ow, oh = xy(o.size)
    cx, cy = cx + ox + ow / 2, cy + oy + oh / 2
  end
  cx, cy = cx / #others, cy / #others
  local bx, by, bov, bd
  for i = 0, GRID_X do
    for j = 0, GRID_Y do
      local x = ax + ex + math.floor((aw - fw - 2 * ex) * i / GRID_X)
      local y = ay + ey + math.floor((ah - fh - 2 * ey) * j / GRID_Y)
      local ov = 0
      for _, o in ipairs(others) do
        local ox, oy = xy(o.at)
        local ow, oh = xy(o.size)
        local dx = math.min(x + fw + GAP, ox + ow) - math.max(x - GAP, ox)
        local dy = math.min(y + fh + GAP, oy + oh) - math.max(y - GAP, oy)
        if dx > 0 and dy > 0 then ov = ov + dx * dy end
      end
      local d = math.abs((x + fw / 2) - cx) + math.abs((y + fh / 2) - cy)
      if not bx or ov < bov or (ov == bov and d < bd) then
        bx, by, bov, bd = x, y, ov, d
      end
    end
  end
  return bx, by
end

-- Give one window the chilled geometry for ws: the others' size, flocked into
-- the least-crowded spot. Used for arrivals with no geometry worth keeping —
-- a window that was just born, or one sent over by a keybind. A window you
-- DRAGGED in keeps its own geometry instead; see adopt_dropped.
local function place_chilled(w, ws)
  local ax, ay, aw, ah = work_area(ws.monitor or hl.get_monitor_at_cursor())
  local others = {}
  for _, o in ipairs(windows_on(ws, chilled)) do
    -- The newcomer is tagged and floating by now, so it would otherwise be
    -- measured against itself — both for the mean size and as an obstacle
    -- every candidate spot overlaps.
    if o.address ~= w.address then others[#others + 1] = o end
  end
  local cls
  pcall(function() cls = w.class end)
  local fw, fh = chilled_size(others, cls, aw, ah)
  fw, fh = math.max(1, fw), math.max(1, fh)
  local x, y = flock_spot(others, fw, fh, ax, ay, aw, ah)
  local ex = math.min(EDGE, math.floor((aw - fw) / 2))
  local ey = math.min(EDGE, math.floor((ah - fh) / 2))
  x = math.max(ax + ex, math.min(x, ax + aw - fw - ex))
  y = math.max(ay + ey, math.min(y, ay + ah - fh - ey))
  on_window(hl.dsp.window.resize, w, { x = fw, y = fh })
  on_window(hl.dsp.window.move, w, { x = x, y = y })
end

-- Tag + float one window and give it the chilled geometry. Float, resize and
-- move go out in one batch so the window never flashes at its tiled size
-- behind the floaters.
local function float_into(w, ws)
  on_window(hl.dsp.window.tag, w, { tag = "+" .. TAG })
  on_window(hl.dsp.window.float, w, { action = "enable" })
  place_chilled(w, ws)
end

-- Adopt a window that was just DROPPED on a chilled workspace: leave it exactly
-- where it was let go, at exactly the size it was carried at. No flocking and
-- no resize to the others' average — you placed it, and second-guessing that is
-- what made a drag feel broken.
--
-- geo is the last geometry the chase saw while the window was still floating,
-- i.e. the drag as it stood a tick before the drop. It has to be replayed:
-- enabling float restores the dragged SIZE by itself, but Hyprland re-centres
-- the window rather than restoring its position (verified 2026-08-26 — dropped
-- at 1700,480 it came back dead centre at 2103,345). Without geo we would keep
-- the size and lose the spot.
local function adopt_dropped(w, geo)
  on_window(hl.dsp.window.tag, w, { tag = "+" .. TAG })
  on_window(hl.dsp.window.float, w, { action = "enable" })
  if geo then
    on_window(hl.dsp.window.resize, w, { x = geo.w, y = geo.h })
    on_window(hl.dsp.window.move, w, { x = geo.x, y = geo.y })
  end
end

-- Our own dispatches can raise window.move_to_workspace themselves: moving a
-- floating window far enough sideways lands it on another monitor, and that is
-- a workspace change. Without a guard the conversion hook re-enters itself
-- mid-conversion and acts on half-applied state — a window came out floating
-- and placed but never tagged (2026-08-25). Everything that converts a window
-- runs inside guarded() so those nested events are ignored.
local converting = false
local function guarded(fn)
  if converting then return end
  converting = true
  local ok, err = pcall(fn)
  converting = false
  if not ok then error(err) end
end

-- Place a window again once a workspace move has settled.
--
-- Hyprland finishes moving a window to its new workspace AFTER the
-- move_to_workspace handler returns, and that tail end repositions the window,
-- silently discarding any position set from inside the handler. The resize
-- survives; the move does not. Verified 2026-08-25: a window landing on a
-- chilled workspace took the right size but kept the coordinates it had had on
-- the workspace it came from, while the identical move dispatched by hand once
-- things had settled worked. So the placement is simply repeated from a
-- one-shot timer, PLACE_DELAY later, by which point the position sticks.
local function schedule_place(w, ws)
  local addr, wsid = w.address, ws.id
  hl.timer(function()
    -- Nothing else will catch a throw inside a timer callback, and the window
    -- may have been destroyed since — pcall so a closed window cannot take the
    -- timer down with it.
    pcall(function()
      guarded(function()
        local win, dest = hl.get_window("address:" .. addr), hl.get_workspace(wsid)
        -- Only if it is still there, still chilled, and still on that
        -- workspace: it may have been closed, untagged, or moved on again
        -- inside the delay.
        if win and dest and has_tag(win) and win.workspace and win.workspace.id == wsid then
          place_chilled(win, dest)
        end
      end)
    end)
  end, { timeout = PLACE_DELAY, type = "oneshot" })
end

-- Chase a window that may be mid-drag.
--
-- A mouse drag moves the window to the hovered workspace MID-drag, and
-- Hyprland reports a dragged window as FLOATING until the drop re-tiles it. So
-- the conversion cannot be decided when the event arrives: at that instant a
-- tiled window being dragged is indistinguishable from a window that was
-- already floating, which chill mode must never touch. Instead we watch it:
-- adopt the first time it shows up TILED on that workspace, and stop early
-- only when it leaves, closes, or someone else has already tagged it.
--
-- Ported from the shell daemon this file replaced (chill-mode-daemon.sh,
-- "Mouse-drag race", 2026-08-21 rev 2). Its rev 1 gave up as soon as the
-- window read floating and so missed every drag — do not reintroduce that.
-- A window that really was floating simply never turns up tiled, the chase
-- times out, and nothing is touched: exactly the wanted behaviour.
local function chase(addr, wsid)
  local n = 0
  local last -- last geometry seen while still floating: the live drag
  local function tick()
    hl.timer(function()
      n = n + 1
      local again = true
      -- Nothing catches a throw inside a timer; a window can vanish mid-chase.
      pcall(function()
        local win = hl.get_window("address:" .. addr)
        if not win or not win.workspace or win.workspace.id ~= wsid then
          again = false -- closed, or moved on somewhere else
        elseif has_tag(win) then
          again = false -- already adopted
        elseif tiled(win) then
          local dest = hl.get_workspace(wsid)
          if dest and chilled_others(dest, win) > 0 then
            guarded(function() adopt_dropped(win, last) end)
          end
          again = false -- it landed; adopted or the workspace is no longer chilled
        else
          -- Still floating: this is the drag in flight. Remember where it is,
          -- because once it re-tiles on the drop that geometry is gone. The
          -- tick is deliberately short so this sample is never far behind the
          -- moment the button was released.
          local x, y = xy(win.at)
          local sw, sh = xy(win.size)
          last = { x = x, y = y, w = sw, h = sh }
        end
      end)
      if again and n < CHASE_TRIES then tick() end
    end, { timeout = CHASE_TICK, type = "oneshot" })
  end
  tick()
end

-- Undo one window's chill: drop the tag, make sure the tag-keyed rounding rule
-- lets go, and hand it back to the tiling layout. Callers that tile several in
-- a row must mind the focus order — see the note in unchill().
local function tile_out(w)
  on_window(hl.dsp.window.tag, w, { tag = "-" .. TAG })
  on_window(hl.dsp.window.set_prop, w, { prop = "rounding", value = "unset" })
  on_window(hl.dsp.window.float, w, { action = "disable" })
end

-- Chill mode's glass and soft corners are PER WINDOW: both ride on the
-- "chillmode" tag (see the window rule at the bottom), so they land on exactly
-- the windows chilled on the workspace you pressed the key on. An earlier
-- version flipped looknfeel's whole custom look instead, which moved gaps,
-- rounding, dimming and opacity on EVERY desktop at once.
--
-- Three parts of the chill feel cannot be scoped, because Hyprland exposes
-- them only globally — window rules can turn blur, shadow and dim OFF but
-- never on (Desktop::Rule::eWindowRuleEffect has NO_BLUR / NO_SHADOW / NO_DIM
-- and no positive counterpart), and workspace rules carry gaps, border,
-- rounding and shadow but no blur and no opacity (Config::CWorkspaceRule).
-- So these three are switched on while a workspace is chilled and put back
-- afterwards:
--
--   blur              only shows through translucent pixels, and nothing
--                     outside chill mode is translucent. Measured 2026-08-26:
--                     0.2% of pixels move on an opaque workspace — the clock
--                     and the cursor.
--   shadow            0.68% on the same test, confined to the gaps between
--                     tiled windows. Visible if you go looking; not otherwise.
--   resize_on_border  no visual effect whatsoever. It only decides whether a
--                     drag on a border resizes, which is what makes chilled
--                     floaters easy to size by hand.
--
-- ignore_opacity goes off with the blur: left on (Hyprland's current default)
-- the blur samples live window content, so a chilled window shows the windows
-- stacked under it instead of the wallpaper.
--
-- Which ones we actually switched is remembered in a file, not an upvalue, so
-- a config reload mid-chill can still put back exactly what it found — and
-- anything already on is left alone, and left alone on the way out too.
local function chill_globals_push()
  local turned = {}
  if hl.get_config("decoration.blur.enabled") ~= true then turned[#turned + 1] = "blur" end
  if hl.get_config("decoration.shadow.enabled") ~= true then turned[#turned + 1] = "shadow" end
  if hl.get_config("general.resize_on_border") ~= true then turned[#turned + 1] = "resize" end
  if #turned == 0 then return end
  local f = io.open(GLOBALS_STATE, "w")
  if f then
    f:write(table.concat(turned, "\n"), "\n")
    f:close()
  end
  hl.config({
    general = { resize_on_border = true },
    decoration = {
      -- xray keeps tiled windows out of the blur backdrop; ignore_opacity
      -- keeps the blur sampling the wallpaper rather than live window content.
      -- Both are pinned here so chill mode looks the same whichever look
      -- SUPER + SHIFT + L happens to be on.
      blur = { enabled = true, ignore_opacity = false, xray = true },
      -- The glow, not a drop shadow: wide range and a soft falloff, strong
      -- under the focused window and almost nothing under the rest.
      shadow = {
        enabled = true,
        range = 90,
        render_power = 2,
        offset = "0 14",
        scale = 0.96,
        color = "rgba(000000cc)",
        color_inactive = "rgba(00000018)",
      },
    },
  })
end

local function chill_globals_pop()
  local f = io.open(GLOBALS_STATE)
  if not f then return end
  local off = {}
  for line in f:lines() do off[line:gsub("%s+", "")] = true end
  f:close()
  os.remove(GLOBALS_STATE)
  local cfg = {}
  if off.blur or off.shadow then
    cfg.decoration = {}
    if off.blur then cfg.decoration.blur = { enabled = false } end
    if off.shadow then cfg.decoration.shadow = { enabled = false } end
  end
  if off.resize then cfg.general = { resize_on_border = false } end
  hl.config(cfg)
end

-- Chill mode is a LOOK, not a re-layout (2026-08-25): every tiled window is
-- floated where it already sits, with every edge pulled in by INSET of that
-- window's own size — so the arrangement you were working in is preserved and
-- the visible change is the air around each window, plus the softened corners
-- from the tag-keyed rounding rule.
--
-- INSET is per SIDE, not per window: at 0.10 a window loses 10% off the left
-- AND 10% off the right, keeping 80% of its width — likewise vertically. The
-- same inset is subtracted from both edges, so the centre does not drift at
-- all and each window shrinks in place rather than drifting toward a corner.
--
-- Geometry is captured for the whole workspace in a first pass, before any
-- float dispatch: floating a window changes its at/size, so reading it lazily
-- inside the apply loop would hand later windows post-float values.
local function chill(ws)
  local wins = windows_on(ws, tiled)
  -- Only once there is something to chill: with no windows nothing gets
  -- tagged, so toggle() would never see a chilled workspace and never call
  -- unchill() to hand the look back.
  if #wins == 0 then return 0 end
  chill_globals_push()
  local geo = {}
  for i, w in ipairs(wins) do
    local x, y = xy(w.at)
    local sw, sh = xy(w.size)
    local ix, iy = math.floor(sw * INSET + 0.5), math.floor(sh * INSET + 0.5)
    geo[i] = { x = x + ix, y = y + iy, w = sw - 2 * ix, h = sh - 2 * iy }
  end
  for i, w in ipairs(wins) do
    local g = geo[i]
    on_window(hl.dsp.window.tag, w, { tag = "+" .. TAG })
    on_window(hl.dsp.window.float, w, { action = "enable" })
    on_window(hl.dsp.window.resize, w, { x = g.w, y = g.h })
    on_window(hl.dsp.window.move, w, { x = g.x, y = g.y })
  end
  return #wins
end


-- ── Putting the chilled arrangement back into the tiling tree ──────────────
--
-- chill() floats each window IN PLACE, so a chilled workspace is still a
-- rectangular partition of the work area — just inset, and possibly dragged
-- around since. That partition is exactly what a dwindle tree is, so it can be
-- read back off the screen and replayed, instead of re-inserting in reading
-- order and taking whatever spiral dwindle happens to produce.
--
-- Dwindle exposes no way to say "split this node vertically at 0.4". What it
-- does expose is enough to get there in three steps, and this is the whole
-- trick the replay rests on:
--
--   which node splits   the newly tiled window lands next to the FOCUSED one,
--                       so focus picks the node (same mechanism the reading
--                       order path already relies on)
--   orientation         layoutmsg togglesplit flips the split we just made
--   side                layoutmsg swapsplit exchanges the two halves
--   ratio               resize the window to the size the partition asks for
--
-- Hyprland 0.56.2's dwindle has no `preselect`, which would have set the
-- orientation up front — checked against the binary, the only messages are
-- togglesplit, swapsplit and movetoroot. Correcting after the fact costs one
-- extra frame per split and gets the same tree.
local TOL = 8 -- px slack when deciding whether an edge lines up

-- The tile a chilled window is asking for: chill()'s inset undone. Every edge
-- came in by INSET of the window's OWN size, so the width grew by a factor of
-- 1/(1-2*INSET) and the top-left moved by half the difference.
local function target_rect(w)
  local x, y = xy(w.at)
  local sw, sh = xy(w.size)
  local ow = sw / (1 - 2 * INSET)
  local oh = sh / (1 - 2 * INSET)
  return { x = x - (ow - sw) / 2, y = y - (oh - sh) / 2, w = ow, h = oh, win = w }
end

local function bbox(rs)
  local x1, y1 = math.huge, math.huge
  local x2, y2 = -math.huge, -math.huge
  for i = 1, #rs do
    local r = rs[i]
    x1, y1 = math.min(x1, r.x), math.min(y1, r.y)
    x2, y2 = math.max(x2, r.x + r.w), math.max(y2, r.y + r.h)
  end
  return { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

-- A guillotine cut: a line with every rect wholly on one side of it. Trying x
-- before y is not arbitrary — dwindle splits a node along its LONGER axis, so
-- preferring the same axis it would have picked keeps the number of
-- togglesplit corrections down. Returns nil when the rects overlap, which is
-- what dragging windows around while chilled can leave behind.
local function guillotine(rs)
  for _, axis in ipairs({ "x", "y" }) do
    local dim = axis == "x" and "w" or "h"
    for i = 1, #rs do
      local cut = rs[i][axis] + rs[i][dim]
      local a, b, clean = {}, {}, true
      for j = 1, #rs do
        local r = rs[j]
        if r[axis] + r[dim] <= cut + TOL then
          a[#a + 1] = r
        elseif r[axis] >= cut - TOL then
          b[#b + 1] = r
        else
          clean = false
          break
        end
      end
      if clean and #a > 0 and #b > 0 then return axis, a, b end
    end
  end
  return nil
end

-- No clean cut: overlapping rects, so there is no tree that reproduces them
-- and the best available answer is the closest one. Split on the axis the
-- windows are most spread along, at the median centre — the same shape of
-- answer the reading order gave, but per node instead of once globally.
local function median_split(rs)
  local box = bbox(rs)
  local axis = box.w >= box.h and "x" or "y"
  local dim = axis == "x" and "w" or "h"
  table.sort(rs, function(p, q) return p[axis] + p[dim] / 2 < q[axis] + q[dim] / 2 end)
  local a, b = {}, {}
  local half = math.floor(#rs / 2)
  for i = 1, #rs do
    if i <= half then a[#a + 1] = rs[i] else b[#b + 1] = rs[i] end
  end
  return axis, a, b
end

local function build_tree(rs)
  if #rs == 1 then return { win = rs[1].win, box = rs[1] } end
  local axis, a, b = guillotine(rs)
  if not axis then axis, a, b = median_split(rs) end
  return { axis = axis, a = build_tree(a), b = build_tree(b), box = bbox(rs) }
end

local function first_win(node)
  while node.a do node = node.a end
  return node.win
end

local function focus_addr(addr)
  hl.dispatch(hl.dsp.focus({ window = "address:" .. addr }))
end

local function geom_of(ws, addr)
  local all = hl.get_windows({ workspace = ws.id })
  for i = 1, #all do
    if all[i].address == addr then
      local x, y = xy(all[i].at)
      local w, h = xy(all[i].size)
      return { x = x, y = y, w = w, h = h }
    end
  end
end

-- hl.dsp.layout takes the message POSITIONALLY. Passed as a table -- any of
-- { message = }, { args = }, { layout = , message = } -- the dispatch is
-- accepted and silently does nothing, which reads as dwindle ignoring the
-- message rather than as a wrong call. Verified 2026-08-27 by toggling a known
-- side-by-side pair and watching for it to stack.
local function layoutmsg(msg)
  hl.dispatch(hl.dsp.layout(msg))
end

-- Split the node that `keep` currently fills, put `add` in the other half, and
-- bend the result until it matches what the partition asked for.
local function split_into(ws, node, keep, add)
  local added = add.address
  focus_addr(keep)
  -- ORDER MATTERS, for the same reason as in the reading order path: dwindle
  -- anchors on the active window only if it is not the window being tiled.
  tile_out(add)
  focus_addr(keep)

  local gk, ga = geom_of(ws, keep), geom_of(ws, added)
  if not gk or not ga then return end

  -- Which way did dwindle actually split? Whichever axis the two halves are
  -- further apart on.
  local got = math.abs(gk.x - ga.x) >= math.abs(gk.y - ga.y) and "x" or "y"
  if got ~= node.axis then
    layoutmsg("togglesplit")
    gk, ga = geom_of(ws, keep), geom_of(ws, added)
    if not gk or not ga then return end
  end

  -- `keep` is the first leaf of the a-side, so it belongs in the lower half.
  if gk[node.axis] > ga[node.axis] then
    layoutmsg("swapsplit")
    gk, ga = geom_of(ws, keep), geom_of(ws, added)
    if not gk or not ga then return end
  end

  -- Ratio. Sizes here are the tiled ones, gaps included, so the split is set
  -- from the fraction rather than from the raw target pixels.
  local dim = node.axis == "x" and "w" or "h"
  local want = node.a.box[dim] / (node.a.box[dim] + node.b.box[dim])
  local total = gk[dim] + ga[dim]
  local px = math.floor(want * total + 0.5)
  if math.abs(px - gk[dim]) > 2 then
    focus_addr(keep)
    hl.dispatch(hl.dsp.window.resize({
      window = "address:" .. keep,
      x = node.axis == "x" and px or gk.w,
      y = node.axis == "y" and px or gk.h,
    }))
  end
end

local function realize(ws, node)
  if not node.a then return end
  split_into(ws, node, first_win(node.a).address, first_win(node.b))
  realize(ws, node.a)
  realize(ws, node.b)
end

-- Reading order — row bands top→bottom, then left→right. Kept as the fallback
-- for the one case the replay cannot handle: a window that was already tiled
-- on the workspace owns part of the tree, and re-inserting it would mean
-- floating a window the user never chilled.
--
-- Sorts on the CHILLED geometry, whose top-left the inset has nudged down and
-- right by INSET of each window's own size. Relative order survives that (the
-- shift is always smaller than the gap to the next window), but a window
-- sitting right on a 350px band edge can land in the next band and tile back
-- one place out. Harmless.
local function retile_in_reading_order(ws, wins, seed)
  table.sort(wins, function(a, b)
    local ax, ay = xy(a.at)
    local bx, by = xy(b.at)
    local ra, rb = math.floor(ay / 350), math.floor(by / 350)
    if ra ~= rb then return ra < rb end
    if ax ~= bx then return ax < bx end
    return a.address < b.address
  end)
  -- Dwindle puts a newly tiled window next to the FOCUSED window
  -- (dwindle:use_active_for_splits). While focus sits on a floater it falls
  -- back to the node nearest the cursor and keeps halving that one corner —
  -- slivers, overlaps, negative sizes. So each window is focused as it tiles
  -- and anchors the next one; a window that was already tiled seeds the chain.
  hl.dispatch(hl.dsp.focus({ window = "address:" .. seed.address }))
  for _, w in ipairs(wins) do
    -- ORDER MATTERS: tile first, focus second. Dwindle anchors a newly tiled
    -- window on the active window ONLY if that window is tiled, on this
    -- workspace, and NOT the window being tiled (DwindleAlgorithm.cpp
    -- addTarget: `ACTIVE_WINDOW != target->window()`). Focusing w before
    -- tiling it makes w its own (excluded) anchor, so dwindle falls back to
    -- the node nearest the cursor and halves that same corner every time —
    -- windows shrink until they vanish. Verified 2026-08-25; don't flip it.
    tile_out(w)
    hl.dispatch(hl.dsp.focus({ window = "address:" .. w.address }))
  end
end

local function unchill(ws)
  local wins = windows_on(ws, chilled)
  if #wins == 0 then return 0 end

  -- Focus changes warp the cursor (deferred a frame, so moving it back
  -- afterwards is a losing race); warps are switched off for the duration and
  -- the setting restored.
  local focused = hl.get_active_window()
  local no_warps = hl.get_config("cursor.no_warps") == true
  hl.config({ cursor = { no_warps = true } })
  local ok, err = pcall(function()
    local seed = windows_on(ws, tiled)[1]
    if seed then return retile_in_reading_order(ws, wins, seed) end
    local rs = {}
    for i = 1, #wins do rs[i] = target_rect(wins[i]) end
    local tree = build_tree(rs)
    -- The first leaf tiles into an empty tree and fills the work area; every
    -- split from here on carves that up.
    tile_out(first_win(tree))
    realize(ws, tree)
  end)
  if focused then hl.dispatch(hl.dsp.focus({ window = "address:" .. focused.address })) end
  hl.config({ cursor = { no_warps = no_warps } })
  -- Restored before the rethrow: a failed re-tile must not strand them.
  chill_globals_pop()
  if not ok then error(err) end
  return #wins
end

local function toggle(selector)
  local ws = selector and hl.get_workspace(selector) or current_workspace()
  if not ws then return end
  local off = #windows_on(ws, chilled) > 0
  local n = off and unchill(ws) or chill(ws)
  notify(string.format("workspace %s — %d window%s %s", ws.name, n, n == 1 and "" or "s",
    off and "back to tiling" or "floating"))
  -- Tell the shell (bar widget) without it having to poll: Hyprland's `event`
  -- dispatcher puts "custom>>chillmode <ws> on|off" on the event socket.
  pcall(function()
    hl.dispatch(hl.dsp.event("chillmode " .. tostring(ws.name) .. " " .. (off and "off" or "on")))
  end)
end

-- { [workspace name] = number of chilled windows }, for UIs catching up.
local function state()
  local out = {}
  local wins = hl.get_windows()
  if type(wins) ~= "table" then return out end
  for i = 1, #wins do
    local w = wins[i]
    if has_tag(w) and w.workspace then
      local k = tostring(w.workspace.name)
      out[k] = (out[k] or 0) + 1
    end
  end
  return out
end

-- ── Registration: re-entrant ─────────────────────────────────────────────
-- The plugin's service dofile()s this file on shell start and after every
-- Hyprland reload; a previous load may still be live (shell restart without a
-- Hyprland reload), so tear that one down first. Everything registered below
-- is kept in `live` so unload() can undo exactly it.
if type(_G.chillmode) == "table" and type(_G.chillmode.unload) == "function" then
  pcall(_G.chillmode.unload)
end
local live = { subs = {}, rules = {}, key = nil }

-- A window born on a chilled workspace joins the vibe instead of tiling
-- full-size behind the floaters.
live.subs[#live.subs + 1] = hl.on("window.open", function(w)
  local ws = w and w.workspace
  if not ws or not tiled(w) or chilled_others(ws, w) == 0 then return end
  float_into(w, ws)
end)

-- Carrying a window across the chill line converts it. A chilled window that
-- lands where nothing else is chilled has arrived on a tiling workspace, so it
-- tiles; a tiled window that lands among chilled ones joins them at their
-- average size. A window that was merely floating stays merely floating --
-- chill mode has never touched those, and a move is no reason to start.
--
-- The destination comes from the event's second argument, not w.workspace:
-- the window's own field is mid-move and need not have caught up, while the
-- argument is by definition where it is going.
live.subs[#live.subs + 1] = hl.on("window.move_to_workspace", function(w, ws)
  ws = ws or (w and w.workspace)
  if not w or not ws then return end
  guarded(function()
    local others = chilled_others(ws, w)
    if has_tag(w) then
      if others == 0 then tile_out(w) end
    elseif others == 0 then
      return -- destination is not chilled; nothing to join
    elseif tiled(w) then
      float_into(w, ws)
      schedule_place(w, ws)
    else
      -- Floating and untagged: either a window that was always floating, which
      -- is never touched, or a tiled window mid-drag. Only chase() can tell
      -- them apart, and it costs nothing when it is the former.
      chase(w.address, ws.id)
    end
  end)
end)

-- The whole chilled look, scoped to the tagged windows: soft corners and the
-- glass. Nothing here touches a window on any other workspace.
live.rules[#live.rules + 1] = hl.window_rule({ match = { tag = TAG }, rounding = ROUNDING, opacity = OPACITY })

-- Toggle key. Omarchy binds SUPER + SHIFT + C to the Calendar webapp; chill
-- mode takes it (mirrors focus mode's SUPER + SHIFT + F), so the previous
-- owner is dropped first. "" in the options means no key at all.
if KEY ~= "" then
  hl.unbind(KEY)
  o.bind(KEY, "Chill mode (float all / tile back)", toggle)
  live.key = KEY
end

local function unload()
  for i = 1, #live.subs do pcall(function() live.subs[i]:remove() end) end
  for i = 1, #live.rules do pcall(function() live.rules[i]:set_enabled(false) end) end
  if live.key then pcall(hl.unbind, live.key) end
  live = { subs = {}, rules = {}, key = nil }
end

_G.chillmode = { toggle = toggle, state = state, unload = unload, version = "1.0.0" }

-- A Hyprland reload (or a fresh injection) starts from a clean config, so the
-- globals chill mode switched on are gone even though the tags survived. Put
-- them back if anything anywhere is still chilled, and re-assert the tag so
-- the rule registered a moment ago is evaluated for windows that were tagged
-- before it existed (runtime rules only apply as windows map or re-tag). The
-- tag stays the only state that has to be right. pcall because a broken load
-- here must not take the whole config down with it.
pcall(function()
  local wins = hl.get_windows()
  if type(wins) ~= "table" then return end
  local any = false
  for i = 1, #wins do
    if has_tag(wins[i]) then
      any = true
      on_window(hl.dsp.window.tag, wins[i], { tag = "-" .. TAG })
      on_window(hl.dsp.window.tag, wins[i], { tag = "+" .. TAG })
    end
  end
  if any then chill_globals_push() end
end)
