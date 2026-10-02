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
--   key_hide  "SUPER + H"           hide the focused window ("" = no key)
--   key_restore "SUPER + SHIFT + H" bring the most recently hidden one back
--   hide      true                  bind the two hide keys at all
--   edge      36                    flocking: px a newcomer keeps from the screen edges
--   gap       16                    flocking: px of breathing room from other windows
--   adopt     true                  a window opened on a chilled workspace floats in
--   convert   true                  moving a window across the chill line converts it
--   auto      false                 a workspace chills itself while it is small
--   auto_max  3                     how many windows still count as small
--   generation  (string)            stamp of the injecting Service instance (see Service.qml)
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
-- With `auto` on, no key is needed on a quiet workspace: it chills itself
-- while it holds at most `auto_max` windows and tiles back the moment the
-- next one arrives -- see the auto-chill section below.
--
-- Scriptable: hyprctl eval 'chillmode.toggle()'  /  'chillmode.toggle(3)'
--             hyprctl eval 'chillmode.hide()'    /  'chillmode.hide("0x...")'
--             hyprctl eval 'chillmode.restore()' /  'chillmode.restore("0x...")'  /  'chillmode.hidden()'
-- State for UIs: every toggle emits a Hyprland custom event
--     custom>>chillmode <workspace name> on|off
-- and `chillmode.state()` returns { [workspace name] = count } for the bar.

local OPTS = type(_G.CHILLMODE_OPTS) == "table" and _G.CHILLMODE_OPTS or {}
local TAG = "chillmode"
local ROUNDING = tonumber(OPTS.rounding) or 14
local SIZE = tonumber(OPTS.size) or 0.72 -- fallback floater size (fraction of the work area)
local INSET = tonumber(OPTS.inset) or 0.10 -- chilled windows pull in this much of their own size on EACH side
local KEY = OPTS.keybind == nil and "SUPER + SHIFT + C" or OPTS.keybind
local KEY_HIDE = OPTS.key_hide == nil and "SUPER + H" or OPTS.key_hide
local KEY_RESTORE = OPTS.key_restore == nil and "SUPER + SHIFT + H" or OPTS.key_restore
local HIDE_KEYS = OPTS.hide ~= false
local ADOPT = OPTS.adopt ~= false
local CONVERT = OPTS.convert ~= false
local NOTIFY = OPTS.notify ~= false
local AUTO = OPTS.auto == true -- off unless asked for: it takes the workspace over
local AUTO_MAX = math.max(0, math.floor(tonumber(OPTS.auto_max) or 3))
local AUTO_DELAY = 60 -- ms to let a workspace settle before auto looks at it
-- Forward declarations. The auto-chill pass itself lives near the bottom --
-- it needs chill() and unchill() -- but chase(), far above it, has to ask
-- whether a window it is about to adopt would take the workspace over the
-- limit. Without these two names as locals up here that call would compile to
-- a global lookup and find nil.
local auto_over, schedule_auto
local PLACE_DELAY = 60 -- ms to let a workspace move settle before placing a window
-- 20ms is one frame at 60Hz: the window is only ever shown at its re-tiled
-- size for about that long before the drop geometry is replayed, which is
-- short enough not to read as a flash. 300 tries keeps the 6s watch window.
local CHASE_TICK, CHASE_TRIES = 20, 300
local GAP = tonumber(OPTS.gap) or 16 -- flocking: overlap padding
local EDGE = tonumber(OPTS.edge) or 36 -- flocking: inset from the screen edges
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

-- ── Groups are one tile ───────────────────────────────────────────────────
-- Tabbed windows share a single tile and a single geometry, so chill mode
-- treats a group as ONE window throughout: one thing to chill, one rectangle
-- to tile back, one window against the auto limit. Chilling the members
-- separately is not a near miss but visibly broken -- three float/resize/move
-- batches land on one shared geometry and the tabs come out at 8 px wide
-- (seen 2026-09-21 on a three-tab group).

-- An address out of whatever hl hands back for a window. Hyprland passes
-- window.group out as USERDATA, not a table, and its members are window
-- userdata too -- measured 2026-09-21 against 0.56.2: `type(w.group)` is
-- "userdata", `g.size` 3, `g.current` userdata carrying an .address. A
-- `type(x) == "table"` guard therefore rejects every real group. pcall: the
-- field need not exist.
local function addr_of(v)
  if v == nil then return nil end
  local a
  pcall(function() a = v.address end)
  return type(a) == "string" and a or nil
end

-- The key a window's group answers with, or nil when it is not grouped. Every
-- member gives the same key -- the group's current window, else the lowest
-- member address -- so whichever member is met first is the one that stands
-- for the group and the rest fold into it. The numeric loop is deliberate:
-- see the note on indexed loops at the top of this file.
local function group_key(w)
  local key
  pcall(function()
    local g = w.group
    if g == nil then return end
    key = addr_of(g.current)
    if key then return end
    local m = g.members
    if type(m) ~= "table" then return end
    for i = 1, #m do
      local a = addr_of(m[i])
      if a and (not key or a < key) then key = a end
    end
  end)
  return key
end

-- One entry per tile: groups collapse to their current (visible) member,
-- whose rectangle is the tile's and whose dispatches move the whole group.
-- The other members may report a stale rect, so the representative matters.
local function by_tile(wins)
  local out, seen = {}, {}
  for i = 1, #wins do
    local w = wins[i]
    local k = group_key(w)
    if not k then
      out[#out + 1] = w
    elseif not seen[k] then
      seen[k] = true
      out[#out + 1] = (w.address == k) and w or (hl.get_window("address:" .. k) or w)
    end
  end
  return out
end

-- Every mapped window sharing w's tile: w itself, plus its fellow tabs.
local function tile_members(w)
  local k = group_key(w)
  if not k or not w.workspace then return { w } end
  local out = {}
  for _, x in ipairs(hl.get_windows({ workspace = w.workspace.id })) do
    if x.mapped and group_key(x) == k then out[#out + 1] = x end
  end
  return #out > 0 and out or { w }
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

-- Hyprflip workspace protection v1
-- Resolve on every call: unloading/reloading the optional plugin must never
-- leave a Lua closure pointing into an unloaded shared library.
local card_holds = {} -- short leases for updating an unloaded compositor plugin
-- Lua is rebuilt during plugin loading. Read leases once on engine load so
-- the gap before the core can register its own reservations is also covered.
local card_holds_file = os.getenv("XDG_RUNTIME_DIR") .. "/hyprflip-chill-holds-"
  .. (os.getenv("HYPRLAND_INSTANCE_SIGNATURE") or "session")
do
  local file = io.open(card_holds_file, "r")
  if file then
    for line in file:lines() do
      local workspace, expiry = line:match("^(%d+) (%d+)$")
      workspace, expiry = tonumber(workspace), tonumber(expiry)
      if workspace and workspace > 0 and workspace < 2147483648 and expiry
        and expiry > os.time() and expiry <= os.time() + 120 then
        card_holds[workspace] = expiry
      end
    end
    file:close()
  end
end

local function card_workspace(ws)
  if not ws or not ws.id then return false end
  if (card_holds[ws.id] or 0) > os.time() then return true end
  local plugin = hl.plugin and hl.plugin.hyprflip
  local check = plugin and (plugin.chill_blocked or plugin.protects_workspace)
  if not check then return false end
  local ok, protected = pcall(check, ws.id)
  return ok and protected == true
end

local function card_protected(ws)
  if not ws or not ws.id then return false end
  if (card_holds[ws.id] or 0) > os.time() then return true end
  local plugin = hl.plugin and hl.plugin.hyprflip
  if not plugin or not plugin.protects_workspace then return false end
  local ok, protected = pcall(plugin.protects_workspace, ws.id)
  return ok and protected == true
end

-- Hyprflip card geometry v2
-- A native Hyprflip card is one native group, but its visible window fills
-- only one pane. Measure the whole card so it chills and tiles back whole.
local function tile_geometry(w)
  local plugin = hl.plugin and hl.plugin.hyprflip
  if plugin and plugin.card_box and w and w.address then
    local ok, x, y, width, height = pcall(plugin.card_box, w.address)
    if ok and x then return x, y, width, height end
  end
  local x, y = xy(w.at)
  local width, height = xy(w.size)
  return x, y, width, height
end

-- Hyprland resizes and moves a group through one window, relative to that
-- window. A card's window is one pane: place a floating card's frame itself,
-- and turn a tiled card size into the size of that pane.
local function place_tile(w, x, y, width, height)
  local plugin = hl.plugin and hl.plugin.hyprflip
  if plugin and plugin.card_place and w and w.address then
    local ok, placed = pcall(plugin.card_place, w.address, x, y, width, height)
    if ok and placed then return end
  end
  on_window(hl.dsp.window.resize, w, { x = width, y = height })
  on_window(hl.dsp.window.move, w, { x = x, y = y })
end

local function pane_inset(addr)
  local w = hl.get_window("address:" .. addr)
  if not w then return 0, 0 end
  local _, _, cw, ch = tile_geometry(w)
  local ww, wh = xy(w.size)
  return cw - ww, ch - wh
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
    local _, _, sw, sh = tile_geometry(o)
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
    local ox, oy, ow, oh = tile_geometry(o)
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
        local ox, oy, ow, oh = tile_geometry(o)
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
  if card_workspace(ws) then return end
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
  place_tile(w, x, y, fw, fh)
end

-- Tag + float one window and give it the chilled geometry. Float, resize and
-- move go out in one batch so the window never flashes at its tiled size
-- behind the floaters.
local function float_into(w, ws)
  if card_workspace(ws) then return end
  -- Tag the whole tile: floating one tab of a group floats them all, and a
  -- tab left untagged would arrive without the look and read as untouched.
  for _, m in ipairs(tile_members(w)) do
    on_window(hl.dsp.window.tag, m, { tag = "+" .. TAG })
  end
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
  if card_workspace(w and w.workspace) then return end
  for _, m in ipairs(tile_members(w)) do
    on_window(hl.dsp.window.tag, m, { tag = "+" .. TAG })
  end
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
        if not win or not win.workspace or win.workspace.id ~= wsid or card_workspace(win.workspace) then
          again = false -- closed, or moved on somewhere else
        elseif has_tag(win) then
          again = false -- already adopted
        elseif tiled(win) then
          local dest = hl.get_workspace(wsid)
          if dest then
            if chilled_others(dest, win) > 0 and not auto_over(dest, win.address) then
              guarded(function() adopt_dropped(win, last) end)
            end
            -- A drop can land seconds after the move event, long after that
            -- one's pass: auto looks again now the window has settled.
            schedule_auto(dest)
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
  -- The tag sits on every tab of a group (see chill), so it has to come off
  -- every tab: one left tagged would keep the chilled corners and glass after
  -- the group tiled, and would still read as chilled to state() and to the
  -- conversion hooks. Only the representative is unfloated -- that is the one
  -- dispatch the whole group follows.
  for _, m in ipairs(tile_members(w)) do
    on_window(hl.dsp.window.tag, m, { tag = "-" .. TAG })
    on_window(hl.dsp.window.set_prop, m, { prop = "rounding", value = "unset" })
  end
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
-- What each global held BEFORE the chill is remembered in a file, not an
-- upvalue, so a config reload mid-chill can still put back exactly what it
-- found — one `key=true|false` line per global (bare words from builds that
-- only remembered what they turned ON read as `word=false`). Values, not
-- flags: pop used to re-disable only what push had enabled, which left the
-- ignore_opacity/xray pins behind on any setup where blur was already on —
-- on a glass theme (foot alpha ~0.3 designed around ignore_opacity=true)
-- that read as "every new terminal is 100% transparent" after the first
-- chill. Push records only when the file is absent: a second workspace
-- chilling, or a re-push after reload, must not overwrite the pre-chill
-- values with the pinned ones.
local GLOBAL_KEYS = {
  blur = "decoration.blur.enabled",
  shadow = "decoration.shadow.enabled",
  resize = "general.resize_on_border",
  ignore_opacity = "decoration.blur.ignore_opacity",
  xray = "decoration.blur.xray",
}

local function chill_globals_push()
  local seen = io.open(GLOBALS_STATE)
  if seen then
    seen:close()
  else
    local lines = {}
    for key, path in pairs(GLOBAL_KEYS) do
      lines[#lines + 1] = key .. "=" .. tostring(hl.get_config(path) == true)
    end
    local f = io.open(GLOBALS_STATE, "w")
    if f then
      f:write(table.concat(lines, "\n"), "\n")
      f:close()
    end
  end
  local cfg = {
    general = { resize_on_border = true },
    decoration = {
      -- xray keeps tiled windows out of the blur backdrop; ignore_opacity
      -- keeps the blur sampling the wallpaper rather than live window content.
      -- Both are pinned here so chill mode looks the same whichever look
      -- SUPER + SHIFT + L happens to be on.
      blur = { enabled = true, ignore_opacity = false, xray = true },
    },
  }
  -- A shadow that is already on is the user's shadow: its parameters are left
  -- alone, and left alone on the way out too. Only when it is off does chill
  -- bring its glow — wide range and a soft falloff, strong under the focused
  -- window and almost nothing under the rest.
  -- Omaglass in its "flat" shadows mode means no shadows at all, glow
  -- included — leave the shadow alone then.
  local flat = type(_G.omaglass) == "table" and _G.omaglass.shadows == "flat"
  if hl.get_config("decoration.shadow.enabled") ~= true and not flat then
    cfg.decoration.shadow = {
      enabled = true,
      range = 90,
      render_power = 2,
      offset = "0 14",
      scale = 0.96,
      color = "rgba(000000cc)",
      color_inactive = "rgba(00000018)",
    }
  end
  hl.config(cfg)
end

local function chill_globals_pop()
  local f = io.open(GLOBALS_STATE)
  if not f then return end
  local prev = {}
  for raw in f:lines() do
    local line = raw:gsub("%s+", "")
    local key, value = line:match("^([%w_]+)=(%a+)$")
    if key then
      prev[key] = value == "true"
    elseif line ~= "" then
      prev[line] = false -- old format: a bare word named a global that was off
    end
  end
  f:close()
  os.remove(GLOBALS_STATE)
  local blur = {}
  if prev.blur ~= nil then blur.enabled = prev.blur end
  if prev.ignore_opacity ~= nil then blur.ignore_opacity = prev.ignore_opacity end
  if prev.xray ~= nil then blur.xray = prev.xray end
  local cfg = {}
  if next(blur) ~= nil or prev.shadow ~= nil then
    cfg.decoration = {}
    if next(blur) ~= nil then cfg.decoration.blur = blur end
    if prev.shadow ~= nil then cfg.decoration.shadow = { enabled = prev.shadow } end
  end
  if prev.resize ~= nil then cfg.general = { resize_on_border = prev.resize } end
  if next(cfg) ~= nil then hl.config(cfg) end
end

-- Anything chilled anywhere? The tag is the only state, so scan the windows;
-- if the list cannot be read, assume something is and keep the globals.
local function any_chilled()
  local wins = hl.get_windows()
  if type(wins) ~= "table" then return true end
  for i = 1, #wins do
    if has_tag(wins[i]) then return true end
  end
  return false
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
  if card_workspace(ws) then return 0 end
  -- A tab added to a group that is ALREADY chilled arrives floating (the
  -- group carries it) and untagged, and no event announces it, so the one
  -- place to catch it is here: re-assert the tag across every chilled tile
  -- before looking for anything new to chill.
  for _, w in ipairs(windows_on(ws, chilled)) do
    for _, m in ipairs(tile_members(w)) do
      if not has_tag(m) then on_window(hl.dsp.window.tag, m, { tag = "+" .. TAG }) end
    end
  end
  local all = windows_on(ws, tiled)
  local wins = by_tile(all) -- one per tile: a group is chilled once, not per tab
  -- Only once there is something to chill: with no windows nothing gets
  -- tagged, so toggle() would never see a chilled workspace and never call
  -- unchill() to hand the look back.
  if #wins == 0 then return 0 end
  chill_globals_push()
  local geo = {}
  for i, w in ipairs(wins) do
    local x, y, sw, sh = tile_geometry(w)
    local ix, iy = math.floor(sw * INSET + 0.5), math.floor(sh * INSET + 0.5)
    geo[i] = { x = x + ix, y = y + iy, w = sw - 2 * ix, h = sh - 2 * iy }
  end
  -- The tag goes on every window, a group's hidden tabs included: the look
  -- rides on it, so it has to be there whichever tab is shown, and chilled()
  -- has to agree about all of them. The geometry goes to the representative
  -- alone -- the group follows it.
  for i = 1, #all do
    on_window(hl.dsp.window.tag, all[i], { tag = "+" .. TAG })
  end
  for i, w in ipairs(wins) do
    local g = geo[i]
    on_window(hl.dsp.window.float, w, { action = "enable" })
    place_tile(w, g.x, g.y, g.w, g.h)
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
  local x, y, sw, sh = tile_geometry(w)
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
      local x, y, w, h = tile_geometry(all[i])
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
    local dw, dh = pane_inset(keep)
    hl.dispatch(hl.dsp.window.resize({
      window = "address:" .. keep,
      x = (node.axis == "x" and px or gk.w) - dw,
      y = (node.axis == "y" and px or gk.h) - dh,
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
  local chilled_wins = windows_on(ws, chilled)
  local wins = by_tile(chilled_wins) -- a group tiles back as the one tile it is
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
  -- Restored before the rethrow — but only once nothing is chilled any more:
  -- another workspace may still be, and (on a failed re-tile) so may this one,
  -- in which case the tags are still there and a reload would re-push anyway.
  if not any_chilled() then chill_globals_pop() end
  if not ok then error(err) end
  return #chilled_wins
end

-- Tell the shell (bar widget) without it having to poll: Hyprland's `event`
-- dispatcher puts "custom>>chillmode <ws> on|off" on the event socket. Every
-- state change goes through here, the ones auto mode makes by itself included,
-- so the sofa never has to guess.
local function announce(ws, off)
  pcall(function()
    hl.dispatch(hl.dsp.event("chillmode " .. tostring(ws.name) .. " " .. (off and "off" or "on")))
  end)
end

-- Self-styled themes (looknfeel's SELF_STYLED_THEMES, e.g. glass-white):
-- their look engine idles in a third "theme" state. Leaving chill there
-- hands the desktop to the square omarchy look, so exiting chill feels the
-- same as on every other theme; entering from omarchy/custom is untouched,
-- and SUPER+SHIFT+L cycles back to the theme look when wanted. pcall: the
-- look engine may not exist at all (stock looknfeel).
local function leave_theme_look()
  pcall(function()
    if _G.look and look.current and look.current() == "theme" then
      look.set("omarchy", true)
    end
  end)
end

-- Hyprflip fullscreen chill v3
-- Chill takes precedence over a fullscreen card: leave fullscreen, then chill.
-- A card that still cannot chill (hy3) gets its fullscreen back.
local function leave_card_fullscreen(ws)
  local plugin = hl.plugin and hl.plugin.hyprflip
  if not plugin or not plugin.card_box then return {} end
  local left = {}
  for _, w in ipairs(hl.get_windows({ workspace = ws.id })) do
    local ok, x = pcall(plugin.card_box, w.address)
    if w.fullscreen ~= 0 and ok and x then
      left[#left + 1] = { w = w, mode = w.fullscreen == 1 and "maximized" or "fullscreen" }
      on_window(hl.dsp.window.fullscreen, w, { action = "unset" })
    end
  end
  return left
end

local function toggle(selector)
  local ws = selector and hl.get_workspace(selector) or current_workspace()
  if not ws then return end
  local off = #windows_on(ws, chilled) > 0
  if card_workspace(ws) and not off then
    local left = leave_card_fullscreen(ws)
    if card_workspace(ws) then
      for _, e in ipairs(left) do on_window(hl.dsp.window.fullscreen, e.w, { mode = e.mode, action = "set" }) end
      notify("This workspace's Hyprflip card can't chill. Ungroup an hy3 card first.")
      return
    end
  end
  local n = off and unchill(ws) or chill(ws)
  if off then leave_theme_look() end
  notify(string.format("workspace %s — %d window%s %s", ws.name, n, n == 1 and "" or "s",
    off and "back to tiling" or "floating"))
  announce(ws, off)
end


-- ── Auto chill: a quiet workspace chills itself ───────────────────────────
-- With `auto` on, chill mode is not something you press: a workspace chills
-- itself while it holds at most AUTO_MAX windows, and tiles back the moment
-- the next one arrives. Drop back under the limit -- close one, hide one,
-- send one elsewhere -- and it chills again. The key still works; auto simply
-- takes the workspace back the next time its window count changes -- or the
-- next time the config is reloaded, when the sweep at the bottom re-asserts
-- the rule everywhere. That is the one thing to keep in mind.
--
-- WHAT COUNTS. The windows chill mode itself acts on: tiled ones, plus the
-- ones already chilled. A window that was floating on its own is never
-- touched by chill mode and must not tip the balance either, or opening a
-- file picker would tile the whole workspace back behind it. Fullscreen
-- counts (it is a tiled window wearing a hat), so leaving fullscreen cannot
-- flip the workspace on its own. A GROUP counts as one, however many tabs it
-- holds: the limit is about how busy the workspace looks, and a group is one
-- tile in one place. Windows parked on a hidden pile live on a special
-- workspace and are simply somewhere else; special workspaces -- the piles,
-- the pads -- are never chilled.
--
-- WHY IT WAITS A TICK. Same reason schedule_place does: when the event
-- arrives the window is not on (or off) the workspace yet, and the layout the
-- others settle into is the one chill() has to capture. So every trigger only
-- queues its workspace, AUTO_DELAY later one pass reads the truth off the
-- compositor and applies it. Several events in the same tick collapse into
-- that one pass.
local unloaded = false -- set by unload(); a timer in flight must not act
local auto_pending = {} -- workspace id -> set of addresses to ignore
local in_auto = false

local function countable(w) return not w.floating or has_tag(w) end

-- Windows on ws that count, one per group, with `extra` counted even if it
-- has not landed yet and every address in `skip` left out (a window that is
-- on its way off). `extra` is counted as one of its own: a window arriving on
-- the workspace is not in a group there yet.
local function auto_count(ws, extra, skip)
  local n, seen = 0, false
  local groups = {}
  for _, x in ipairs(windows_on(ws, countable)) do
    if not (skip and skip[x.address]) then
      local g = group_key(x)
      if not g then
        n = n + 1
      elseif not groups[g] then
        groups[g] = true
        n = n + 1
      end
      if extra and x.address == extra then seen = true end
    end
  end
  if extra and not seen and not (skip and skip[extra]) then n = n + 1 end
  return n
end

-- Would ws be over the limit with `addr` on it? Asked before adopting a
-- newcomer into a chilled workspace: one that tips it over must not be
-- floated in for the frame before the whole workspace tiles back.
function auto_over(ws, addr)
  return AUTO and ws ~= nil and not ws.special and auto_count(ws, addr) > AUTO_MAX
end

-- Bring one workspace to the state auto mode asks for.
local function auto_apply(ws, skip)
  if not AUTO or unloaded or in_auto or not ws or ws.special or card_workspace(ws) then return end
  local n = auto_count(ws, nil, skip)
  local on = #windows_on(ws, chilled) > 0
  local want = n > 0 and n <= AUTO_MAX
  if not want and not on then return end -- already tiling, or empty
  in_auto = true
  local ok, err = pcall(function()
    -- Spelled out rather than `want and chill(ws) or unchill(ws)`: chill()
    -- returns 0 on a workspace that is already chilled with no tiled
    -- straggler standing there, and `and/or` would fall straight through that
    -- zero into unchill() -- tiling back the very workspace auto wants
    -- chilled. A straggler (adopt off, a rule that floated something back) is
    -- what that repeat chill() is for.
    local moved
    if want then moved = chill(ws) else moved = unchill(ws) end
    if moved > 0 then
      if not want then leave_theme_look() end
      announce(ws, not want)
    end
  end)
  in_auto = false
  if not ok then error(err) end
end

function schedule_auto(ws, exclude)
  if not AUTO or unloaded or not ws or ws.special then return end
  local id = ws.id
  if id == nil then return end
  local queued = auto_pending[id]
  if queued then -- a pass is already on its way; fold this trigger into it
    if exclude then queued[exclude] = true end
    return
  end
  queued = {}
  if exclude then queued[exclude] = true end
  auto_pending[id] = queued
  hl.timer(function()
    auto_pending[id] = nil
    -- Nothing else catches a throw inside a timer callback, and the
    -- workspace may be gone (the last window on it closed).
    pcall(function()
      local dest = hl.get_workspace(id)
      if dest then auto_apply(dest, queued) end
    end)
  end, { timeout = AUTO_DELAY, type = "oneshot" })
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


-- ── Hide / restore ────────────────────────────────────────────────────────
-- KEY_HIDE parks the focused window on its monitor's hidden pile (a special
-- workspace), KEY_RESTORE brings the most recently hidden one back onto the
-- workspace you are looking at -- macOS Cmd+H. Moved in from
-- ~/.config/hypr/hide.lua (2026-09-05): it already rode on chill mode's tag,
-- inset and rounding, and shares every geometry helper above.
--
--   * A TILED window is floated in place first -- float, resize and move go
--     out in one batch, so it is never drawn anywhere but where it already
--     is -- and only then sent to the pile. Sent tiled, Hyprland re-tiles it
--     into the pile's full work area, and a window fading into an invisible
--     workspace is still rendered (Renderer.cpp shouldRenderWindow /
--     WINDOW_ALPHA_MOVE_TO_WORKSPACE, checked against v0.56.2), so that
--     re-tile showed as a grow-to-fullscreen during the fade-out.
--   * Coming back, the window fades in floating at exactly the rect it was
--     hidden from, then is tiled INTO that rect: the tiled neighbour covering
--     the old spot is split along the old edge, on the old side, at the old
--     ratio -- the same bend-the-fresh-split trick as split_into. With the
--     same neighbours as before the layout comes back exactly; otherwise it
--     is the closest tiling that still has the window where it was.
--   * A CHILLED window drops the tag for the trip (keeping the corners, so
--     the fade looks right); the engine would otherwise tile it into the
--     pile and re-flock it on the way back at the others' average size. It
--     gets the tag back if it lands among chilled windows. Rects cross the
--     chill line the way toggle does: a chilled window returning to a tiling
--     workspace grows out of its inset, a tiled one landing among chilled
--     floaters takes the inset.
--   * Rects are remembered as fractions of the origin monitor's work area,
--     so a window restored on another monitor lands in the same relative spot.
--   * Fullscreen / maximised comes off for the trip and goes back on. Focus
--     follows the restored window; the cursor stays where it is.
--
-- One pile per monitor: special workspaces are monitor-bound, and a single
-- "special:hidden" dragged a window hidden on another monitor over to the
-- pile's monitor mid-fade. A pre-existing plain "special:hidden" is still
-- drained by restore. The stack (most recently hidden restored first) is
-- mirrored to HIDDEN_STATE, so a config reload -- which rebuilds this Lua
-- state -- forgets neither the order nor the rects. Windows that reached a
-- pile some other way are still restored, last, with nothing to replay.
local PILE_PREFIX = "special:hidden"
local HIDDEN_STATE = os.getenv("HOME") .. "/.local/state/hypr-chill-hidden"
local HIDDEN_STATE_LEGACY = os.getenv("HOME") .. "/.local/state/hypr-hidden-windows" -- hide.lua's, same format

local function pile_for(mon) return PILE_PREFIX .. "-" .. tostring(mon.name) end
local function on_pile(w)
  local ws = w.workspace
  local name = ws and tostring(ws.name) or ""
  return name:sub(1, #PILE_PREFIX) == PILE_PREFIX
end

local function on_addr(fn, addr, opts)
  opts = opts or {}
  opts.window = "address:" .. addr
  hl.dispatch(fn(opts))
end

local function rect_of(w)
  local x, y = xy(w.at)
  local sw, sh = xy(w.size)
  return { x = x, y = y, w = sw, h = sh }
end

local function area_of(m)
  local x, y, w, h = work_area(m)
  return { x = x, y = y, w = w, h = h }
end

local function round(v) return math.floor(v + 0.5) end

-- Exact floating geometry. Resize first: a floating resize keeps the centre
-- (DefaultFloatingAlgorithm::resizeTarget), so the move has the last word.
local function set_rect(addr, r)
  on_addr(hl.dsp.window.resize, addr, { x = math.max(1, round(r.w)), y = math.max(1, round(r.h)) })
  on_addr(hl.dsp.window.move, addr, { x = round(r.x), y = round(r.y) })
end

-- The same rect in another work area, by fractions.
local function map_rect(r, from, to)
  if from.x == to.x and from.y == to.y and from.w == to.w and from.h == to.h then
    return { x = r.x, y = r.y, w = r.w, h = r.h }
  end
  local sx, sy = to.w / from.w, to.h / from.h
  return { x = to.x + (r.x - from.x) * sx, y = to.y + (r.y - from.y) * sy, w = r.w * sx, h = r.h * sy }
end

-- chill()'s inset -- every side pulled in by k of the window's own size --
-- and its inverse (target_rect above does the same for a live window).
local function inset_rect(r, k)
  local ix, iy = r.w * k, r.h * k
  return { x = r.x + ix, y = r.y + iy, w = r.w - 2 * ix, h = r.h - 2 * iy }
end
local function outset_rect(r, k)
  local ow, oh = r.w / (1 - 2 * k), r.h / (1 - 2 * k)
  return { x = r.x - (ow - r.w) / 2, y = r.y - (oh - r.h) / 2, w = ow, h = oh }
end

-- The stack: oldest first, restore pops from the end. Entry: addr, ws (origin
-- workspace id), floating, chilled, fs (0 none / 1 maximised / 2 fullscreen),
-- rect, and area -- the origin monitor's work area, for cross-monitor mapping.
local hidden = {}

local function save_hidden()
  local f = io.open(HIDDEN_STATE, "w")
  if not f then return end
  for i = 1, #hidden do
    local e = hidden[i]
    f:write(string.format("%s %d %d %d %d %d %d %d %d %d %d %d %d\n",
      e.addr, e.ws, e.floating and 1 or 0, e.chilled and 1 or 0, e.fs,
      round(e.rect.x), round(e.rect.y), round(e.rect.w), round(e.rect.h),
      round(e.area.x), round(e.area.y), round(e.area.w), round(e.area.h)))
  end
  f:close()
end

local function load_hidden()
  local f, legacy = io.open(HIDDEN_STATE, "r"), false
  if not f then
    f, legacy = io.open(HIDDEN_STATE_LEGACY, "r"), true -- hide.lua's stack, taken over once
  end
  if not f then return end
  for line in f:lines() do
    local t = {}
    for tok in line:gmatch("%S+") do t[#t + 1] = tok end
    if #t == 13 then
      hidden[#hidden + 1] = {
        addr = t[1], ws = tonumber(t[2]) or 0, floating = t[3] == "1", chilled = t[4] == "1", fs = tonumber(t[5]) or 0,
        rect = { x = tonumber(t[6]) or 0, y = tonumber(t[7]) or 0, w = tonumber(t[8]) or 1, h = tonumber(t[9]) or 1 },
        area = { x = tonumber(t[10]) or 0, y = tonumber(t[11]) or 0, w = tonumber(t[12]) or 1, h = tonumber(t[13]) or 1 },
      }
    end
  end
  f:close()
  if legacy then
    save_hidden()
    os.remove(HIDDEN_STATE_LEGACY)
  end
end
pcall(load_hidden)

local function hide(addr)
  local w = addr and hl.get_window("address:" .. addr) or hl.get_active_window()
  if not w or not w.mapped or w.pinned then return end
  local ws = w.workspace
  if not ws or ws.special then return end
  addr = w.address

  -- Fullscreen off first: resize/move refuse a fullscreen window, and the
  -- rect worth keeping is the one underneath.
  local fs = tonumber(w.fullscreen) or 0
  if fs ~= 0 then
    on_addr(hl.dsp.window.fullscreen, addr, { action = "unset" })
    w = hl.get_window("address:" .. addr)
    if not w then return end
  end

  local mon = w.monitor or ws.monitor or hl.get_monitor_at_cursor()
  if not mon then return end
  local was_chilled = chilled(w)
  local entry = { addr = addr, ws = ws.id, floating = w.floating, chilled = was_chilled, fs = fs,
    rect = rect_of(w), area = area_of(mon) }
  for k = #hidden, 1, -1 do
    if hidden[k].addr == addr then table.remove(hidden, k) end
  end
  hidden[#hidden + 1] = entry
  save_hidden()

  if was_chilled then
    -- Keep the chilled corners through the fade (the rule goes with the tag),
    -- then drop the tag so the engine sees a plain floater it never touches
    -- rather than a chilled window crossing onto a tiling workspace.
    on_addr(hl.dsp.window.set_prop, addr, { prop = "rounding", value = tostring(ROUNDING) })
    on_addr(hl.dsp.window.tag, addr, { tag = "-" .. TAG })
  elseif not w.floating then
    -- Float in place. Floating picks a centred "last floating size"; the
    -- resize and move in the same batch put the tiled rect back before a
    -- frame is drawn, so on screen nothing moves.
    on_addr(hl.dsp.window.float, addr, { action = "enable" })
    set_rect(addr, entry.rect)
  end
  on_addr(hl.dsp.window.move, addr, { workspace = pile_for(mon), follow = false })
end

-- Tile `addr` (floating on ws, sitting at R) back into the layout AT R.
-- Dwindle has no "split this node here". What it has: a newly tiled window
-- splits the FOCUSED window's node, togglesplit flips that split's
-- orientation, swapsplit its side, and a resize sets its ratio. So: pick the
-- tiled window whose rect covers most of R, focus it, tile in, then bend the
-- fresh split until it matches -- all inside one handler, so no intermediate
-- state is ever drawn (split_into does the same for a whole tree).
local function tile_into(ws, addr, R)
  local best, best_ov, best_d
  local wins = hl.get_windows({ workspace = ws.id })
  for i = 1, #wins do
    local o = wins[i]
    if o.mapped and not o.floating and (tonumber(o.fullscreen) or 0) == 0 and o.address ~= addr then
      local b = rect_of(o)
      local dx = math.min(R.x + R.w, b.x + b.w) - math.max(R.x, b.x)
      local dy = math.min(R.y + R.h, b.y + b.h) - math.max(R.y, b.y)
      local ov = (dx > 0 and dy > 0) and dx * dy or 0
      local d = math.abs((b.x + b.w / 2) - (R.x + R.w / 2)) + math.abs((b.y + b.h / 2) - (R.y + R.h / 2))
      if not best or ov > best_ov or (ov == best_ov and d < best_d) then
        best, best_ov, best_d = o.address, ov, d
      end
    end
  end
  if not best then
    on_addr(hl.dsp.window.float, addr, { action = "disable" }) -- alone: it fills the workspace
    return
  end
  local B = geom_of(ws, best)
  if not B then return end

  -- Which way to cut B so the window gets R back: a band across B's width is
  -- a top/bottom cut ("y"), one across its height a left/right cut ("x").
  -- Neither lines up when the layout changed meanwhile: cut along whichever
  -- R spans more of.
  local axis
  if math.abs(R.w - B.w) <= TOL then
    axis = "y"
  elseif math.abs(R.h - B.h) <= TOL then
    axis = "x"
  else
    axis = (R.w / B.w >= R.h / B.h) and "y" or "x"
  end
  local dim = axis == "x" and "w" or "h"
  local first = (R[axis] + R[dim] / 2) < (B[axis] + B[dim] / 2) -- left/top of the neighbour

  focus_addr(best)
  on_addr(hl.dsp.window.float, addr, { action = "disable" })
  local gb, gw = geom_of(ws, best), geom_of(ws, addr)
  if not gb or not gw then return end

  -- Orientation: whichever axis the two now differ on more is the one
  -- dwindle cut along.
  local got = math.abs(gb.x - gw.x) >= math.abs(gb.y - gw.y) and "x" or "y"
  if got ~= axis then
    layoutmsg("togglesplit")
    gb, gw = geom_of(ws, best), geom_of(ws, addr)
    if not gb or not gw then return end
  end
  if (gw[axis] < gb[axis]) ~= first then
    layoutmsg("swapsplit")
    gb, gw = geom_of(ws, best), geom_of(ws, addr)
    if not gb or not gw then return end
  end

  -- Ratio. A resize on either child adds its delta to the parent's split
  -- ratio, which grows the FIRST child (DwindleAlgorithm::resizeTarget) --
  -- so always size whichever of the two comes first.
  local total = gb[dim] + gw[dim]
  local want = math.max(0.1 * total, math.min(0.9 * total, R[dim]))
  local tgt, cur = (first and addr or best), (first and gw or gb)
  local px = round(first and want or total - want)
  if math.abs(px - cur[dim]) > 2 then
    on_addr(hl.dsp.window.resize, tgt, { x = axis == "x" and px or cur.w, y = axis == "y" and px or cur.h })
  end
end

local function restore_entry(e, ws)
  local w = hl.get_window("address:" .. e.addr)
  if not w or not w.mapped or not on_pile(w) then return false end
  local mon = ws.monitor or hl.get_monitor_at_cursor()
  if not mon then return false end
  local addr = e.addr
  local R = map_rect(e.rect, e.area, area_of(mon))

  -- Back onto the workspace, focused. Floating for the trip, it arrives at
  -- the same monitor-relative spot; set_rect re-asserts the rect (a no-op on
  -- the same monitor, the mapped spot on another).
  on_addr(hl.dsp.window.move, addr, { workspace = tostring(ws.id), follow = true })
  if e.floating and not e.chilled then
    set_rect(addr, R)
  elseif chilled_others(ws, { address = addr }) > 0 then
    -- Among chilled windows: join them, at chill()'s inset if it was a tile.
    if not e.chilled then R = inset_rect(R, INSET) end
    on_addr(hl.dsp.window.set_prop, addr, { prop = "rounding", value = "unset" })
    on_addr(hl.dsp.window.tag, addr, { tag = "+" .. TAG })
    set_rect(addr, R)
  else
    -- A tiling workspace: back into the layout, a chilled rect first grown
    -- out of its inset (what un-chill would have done to it).
    if e.chilled then R = outset_rect(R, INSET) end
    on_addr(hl.dsp.window.set_prop, addr, { prop = "rounding", value = "unset" })
    set_rect(addr, R)
    tile_into(ws, addr, R)
    focus_addr(addr)
  end
  if e.fs ~= 0 then
    on_addr(hl.dsp.window.fullscreen, addr, { action = "set", mode = e.fs == 1 and "maximized" or "fullscreen" })
  end
  return true
end

-- The workspace the user is looking at: the focused window's, unless that is
-- a special one (a pad in front), else the one under the cursor.
-- hl.get_active_workspace() follows the "focused monitor", which lags behind
-- a focus moved by dispatch; the focused window itself never does.
local function looking_at()
  local w = hl.get_active_window()
  if w and w.workspace and not w.workspace.special then return w.workspace end
  local m = hl.get_monitor_at_cursor()
  return m and m.active_workspace
end

-- restore(): the most recently hidden window. restore(addr): that one, if it
-- is tracked; a window on a pile that never went through hide() comes back
-- plainly.
local function restore(addr)
  local ws = looking_at()
  if not ws then return end
  -- The follow-move and every focus change warp the cursor: keep it put. A
  -- manual resize normally snaps without animating: let the neighbours slide
  -- into their new sizes instead.
  local no_warps = hl.get_config("cursor.no_warps") == true
  local animate = hl.get_config("misc.animate_manual_resizes") == true
  hl.config({ cursor = { no_warps = true }, misc = { animate_manual_resizes = true } })
  local ok, err = pcall(function()
    if addr then
      for k = #hidden, 1, -1 do
        if hidden[k].addr == addr then
          local e = table.remove(hidden, k)
          local done = restore_entry(e, ws)
          save_hidden()
          if done then return end
          break
        end
      end
      local w = hl.get_window("address:" .. addr)
      if w and w.mapped and on_pile(w) then
        on_addr(hl.dsp.window.move, addr, { workspace = tostring(ws.id), follow = true })
      end
      return
    end
    while #hidden > 0 do
      local e = table.remove(hidden)
      if restore_entry(e, ws) then
        save_hidden()
        return
      end
    end
    save_hidden()
    -- Nothing tracked left: anything else on a pile (hidden some other way,
    -- or before this existed) comes back the plain way.
    local wins = hl.get_windows()
    for i = 1, #wins do
      local w = wins[i]
      if w.mapped and on_pile(w) then
        on_addr(hl.dsp.window.move, w.address, { workspace = tostring(ws.id), follow = true })
        return
      end
    end
  end)
  hl.config({ cursor = { no_warps = no_warps }, misc = { animate_manual_resizes = animate } })
  if not ok then error(err) end
end

-- ── Registration: re-entrant ─────────────────────────────────────────────
-- The plugin's service dofile()s this file on shell start and after every
-- Hyprland reload; a previous load may still be live (shell restart without a
-- Hyprland reload), so tear that one down first. Everything registered below
-- is kept in `live` so unload() can undo exactly it.
if type(_G.chillmode) == "table" and type(_G.chillmode.unload) == "function" then
  pcall(_G.chillmode.unload)
end
local live = { subs = {}, rules = {}, keys = {} }

-- A window born on a chilled workspace joins the vibe instead of tiling
-- full-size behind the floaters -- unless it is the one that takes the
-- workspace over auto mode's limit, in which case floating it in would only
-- show it among the others for the frame before they all tile back.
live.subs[#live.subs + 1] = hl.on("window.open", function(w)
  local ws = w and w.workspace
  if not ws then return end
  if ADOPT and tiled(w) and chilled_others(ws, w) > 0 and not auto_over(ws, w.address) then
    float_into(w, ws)
  end
  schedule_auto(ws)
end)

-- One window fewer can put the workspace back under the limit. The address is
-- handed on so the pass ignores it: the window may still be in the list while
-- it fades out.
live.subs[#live.subs + 1] = hl.on("window.close", function(w)
  if not AUTO then return end
  pcall(function() schedule_auto(w and w.workspace, w and w.address) end)
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
  local from = w and w.workspace
  ws = ws or from
  if not w or not ws then return end
  -- Both ends change: the workspace it left may fall under the limit, the one
  -- it lands on may rise over it. `from` is the workspace the window is still
  -- recorded on -- it need not have caught up, so it is only worth a pass of
  -- its own when it differs from the destination, and the window itself is
  -- discounted there because it is on its way out.
  schedule_auto(ws)
  if from and from.id ~= ws.id then schedule_auto(from, w.address) end
  if not CONVERT or card_workspace(ws) then return end
  guarded(function()
    local others = chilled_others(ws, w)
    if has_tag(w) then
      if others == 0 then tile_out(w) end
    elseif others == 0 then
      return -- destination is not chilled; nothing to join
    elseif tiled(w) then
      -- Over auto mode's limit it stays tiled and the workspace tiles back
      -- around it, the same call the open hook makes.
      if auto_over(ws, w.address) then return end
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

-- Keys. Omarchy binds SUPER + SHIFT + C to the Calendar webapp; chill mode
-- takes it (mirrors focus mode's SUPER + SHIFT + F), so the previous owner
-- is always dropped first. "" in the options means no key at all.
local function bind_key(key, label, fn)
  if key == nil or key == "" then return end
  hl.unbind(key)
  o.bind(key, label, fn)
  live.keys[#live.keys + 1] = key
end
bind_key(KEY, "Chill mode (float all / tile back)", toggle)
if HIDE_KEYS then
  bind_key(KEY_HIDE, "Hide window", function() hide() end)
  bind_key(KEY_RESTORE, "Restore hidden window", function() restore() end)
end

local function unload()
  unloaded = true -- an auto pass already on a timer must not chill anything now
  for i = 1, #live.subs do pcall(function() live.subs[i]:remove() end) end
  for i = 1, #live.rules do pcall(function() live.rules[i]:set_enabled(false) end) end
  for i = 1, #live.keys do pcall(hl.unbind, live.keys[i]) end
  live = { subs = {}, rules = {}, keys = {} }
  _G.hidewin = nil
  -- Leaving for good (plugin disabled/removed) rather than about to be
  -- re-injected: if nothing is chilled any more, hand back the globals we
  -- switched on and drop the state file, so nothing of ours outlives us.
  pcall(function()
    if not any_chilled() then chill_globals_pop() end
  end)
  _G.chillmode = nil
end

-- `generation` is the injecting Service instance's stamp: its unload-on-
-- destruction only fires when this is still its own engine (see Service.qml).
-- The picker has already reserved the workspace and collected every choice.
-- Hand over only the selected ungrouped app; leave unrelated floaters alone.
local function handoff(address)
  local w = hl.get_window("address:" .. address)
  if not w or not w.mapped or not card_protected(w.workspace) then return false end
  if #tile_members(w) ~= 1 or w.fullscreen ~= 0 then return false end
  guarded(function() tile_out(w) end)
  if not any_chilled() then chill_globals_pop() end
  return true
end

local function handback(address, x, y, width, height)
  local w = hl.get_window("address:" .. address)
  if not w or not w.mapped or #tile_members(w) ~= 1 or w.fullscreen ~= 0 then return false end
  chill_globals_push()
  guarded(function()
    on_window(hl.dsp.window.tag, w, { tag = "+" .. TAG })
    on_window(hl.dsp.window.float, w, { action = "enable" })
    on_window(hl.dsp.window.resize, w, { x = width, y = height })
    on_window(hl.dsp.window.move, w, { x = x, y = y })
  end)
  return true
end

local function hold_workspace(workspace, seconds)
  if type(workspace) ~= "number" or workspace < 1 then return false end
  if type(seconds) ~= "number" or seconds < 0 or seconds > 120 then return false end
  card_holds[workspace] = seconds > 0 and (os.time() + seconds) or nil
  local temporary = card_holds_file .. ".new"
  local file = io.open(temporary, "w")
  if not file then return false end
  for id, expiry in pairs(card_holds) do
    if expiry > os.time() then file:write(string.format("%d %d\n", id, expiry)) end
  end
  file:close()
  local ok = os.rename(temporary, card_holds_file)
  if not ok then os.remove(temporary) return false end
  return true
end

_G.chillmode = { hold_workspace = hold_workspace, handoff = handoff, handback = handback, toggle = toggle, state = state, hide = hide, restore = restore,
  hidden = function() return hidden end, unload = unload, version = "1.2.0",
  generation = OPTS.generation }
-- hide.lua's name for the same calls, so scripts written against it keep working.
_G.hidewin = { hide = hide, restore = restore, stack = function() return hidden end }

-- Auto mode may have been switched on, or its limit changed, while windows
-- were already open -- and this file is re-run on every reload. So sweep every
-- workspace that has windows on it once the dust settles. A timer scheduled
-- while the config is still being PARSED never fires (this file is dofile()d
-- from hyprland.lua), so the sweep also hangs off config.reloaded, which fires
-- once the parse is done; whichever arrives first does it, and a second pass
-- costs nothing because it is idempotent.
if AUTO then
  local function auto_sweep()
    local wins = hl.get_windows()
    if type(wins) ~= "table" then return end
    local seen = {}
    for i = 1, #wins do
      local w = wins[i]
      local ws = w.mapped and w.workspace or nil
      if ws and ws.id and not seen[ws.id] then
        seen[ws.id] = true
        schedule_auto(ws)
      end
    end
  end
  live.subs[#live.subs + 1] = hl.on("config.reloaded", function() pcall(auto_sweep) end)
  hl.timer(function() pcall(auto_sweep) end, { timeout = 200, type = "oneshot" })
end

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
