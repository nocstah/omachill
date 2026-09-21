# Omachill

Float every window on the current workspace **in place** — each pulled in a
little on all four sides (10 % by default), with soft corners and glass — and
press again to tile them back exactly where they were. A look, not a
re-layout: your arrangement is preserved, the visible change is the air around
each window. Or never press it: switch **auto chill** on and a workspace
chills itself while it is quiet — up to your limit of windows — and tiles back
the moment the next one arrives. Plus macOS-style hide and restore:
`SUPER + H` parks a window, `SUPER + SHIFT + H` brings it back exactly where
it was.

Only the workspace you press it on changes. Everything else is left alone.
Companion to [Omaglass](https://github.com/nocstah/omaglass), which draws the
glass on every theme; each works without the other.

| Tiled | Chilled |
| :---: | :---: |
| ![Light theme, tiled](docs/screenshots/light-tiled.png) | ![Light theme, chilled](docs/screenshots/light-chilled.png) |
| ![Dark theme, tiled](docs/screenshots/dark-tiled.png) | ![Dark theme, chilled](docs/screenshots/dark-chilled.png) |

## Install

```bash
omarchy plugin add https://github.com/nocstah/omachill --enable
```

If the `--enable` half answers `omarchy-shell is not responding` (the shell
was still reloading plugins), the plugin is installed — just run
`omarchy plugin enable io.github.nocstah.omachill` once more.

That is the whole install. The plugin ships its engine as Hyprland Lua. On
enable it writes a small loader, `~/.config/hypr/omachill.lua` (the widget's
settings plus a `dofile` of the engine), and appends one guarded, marked line
to `~/.config/hypr/hyprland.lua` that runs that loader if it exists. Hyprland
rebuilds its Lua state from the config on every `hyprctl reload`, so this is
what keeps the engine alive across reloads; the shell also injects it
directly (`hyprctl eval`) for immediate effect. Disabling or removing the
plugin removes the loader again, and the include line is inert without it.

To remove it:

```bash
omarchy plugin remove io.github.nocstah.omachill
```

That deletes the loader and unbinds the keys; the marked include line left in
`hyprland.lua` is inert and safe to delete, and the two small state files
under `~/.local/state/` (`hypr-chill-globals`, `hypr-chill-hidden`) can go too.

Default key: `SUPER + SHIFT + C` (Omarchy's Calendar webapp sits there by
default and is unbound while the plugin is enabled; change the key in the
widget's settings).

## What it does

- **Chill** — every *tiled* window on the workspace floats where it sits,
  keeping 80 % of its width and height, centred on the same spot. Windows that
  were already floating are never touched.
- **Tile back** — the chilled rectangles are read back into a dwindle tree and
  replayed, so windows return to their original places, not to whatever spiral
  dwindle would produce from scratch.
- **Newcomers join** — a window opened on a chilled workspace floats in at the
  size of the windows already there, flocked into the least-crowded gap.
- **Crossing the line converts** — a chilled window moved to a tiling
  workspace tiles; a tiled window moved onto a chilled workspace joins the
  floaters. A window you *drag* in keeps the spot and size you dropped it at.
- **A group is one window** — tabbed windows share a single tile, so chill
  mode chills them, tiles them back and counts them as one.
- **Chills by itself** — optional: a workspace holding no more than your
  limit of windows is chilled without asking. See below.
- **Reload-proof** — the `chillmode` window tag is the only state, so a
  Hyprland reload or a shell restart cannot lose track of what is chilled.

## Chill by itself

Switch `auto` on and chill mode stops being something you press. A workspace
chills itself while it holds at most `autoMax` windows (3 by default) and
tiles back the moment the next one arrives; drop under the limit again — close
one, hide one, send one to another desktop — and it chills again. An empty
workspace counts as chilled: the first window you open on it chills as it
settles, a frame or two after it lands.

```bash
omarchy bar set io.github.nocstah.omachill auto true --json
omarchy bar set io.github.nocstah.omachill autoMax 3 --json
```

What counts is what chill mode itself touches: the tiled windows plus the ones
already chilled. A window that was floating on its own — a file picker, a
dialog, a picture-in-picture — is never counted, so it cannot tile a workspace
back behind it, and a window on a hidden pile is simply somewhere else.
Fullscreen counts as the tiled window it is. A **group counts as one**,
however many tabs it holds — it is one tile in one place, and tiles are what
the limit is about. Special workspaces — the hidden piles, Omarchy's pads —
are left alone.

Grouping or ungrouping fires no event of its own, so a group formed while the
workspace just sits there is taken into account the next time its window count
changes.

The key still works while auto is on: it chills or tiles back right away, and
auto takes the workspace over again the next time its window count changes —
or the next time Hyprland reloads its config, which re-asserts the rule
everywhere. Auto's own changes are silent, whatever `notify` says.

## Hide and restore (Cmd+H)

`SUPER + H` parks the focused window on its monitor's hidden pile, a special
workspace; `SUPER + SHIFT + H` brings the most recently hidden window back
onto the workspace you are looking at. The window comes back exactly where it
was: a tiled window is tiled *into* its old rectangle (the neighbour covering
the spot is split along the old edge at the old ratio), a floating one lands
at its old spot, a chilled one rejoins the floaters, fullscreen and maximised
come back too, and a window restored on another monitor lands in the same
relative place. The stack survives reloads (`~/.local/state/hypr-chill-hidden`).
Both keys are settings (`keyHide`, `keyRestore`; empty = no key).

## Bar widget and panel

The sofa lights up while the workspace on that monitor is chilled; click to
toggle. Right-click opens the panel: the workspace's state with a toggle,
every chilled workspace with a "tile back", the hidden windows with a
"restore" each, and behind the cog every setting: the keys, how much a window
shrinks (`inset`), the newcomer size, the corner radius, the flocking edge
margin and gap, whether new windows join and moves convert, whether a quiet
workspace chills itself and up to how many windows, whether the hide keys are
bound, notifications, hide-when-idle. Changes apply on the spot. The
same settings can be set with `omarchy bar set io.github.nocstah.omachill
<key> <value>`; they are stored in `~/.config/omarchy/shell.json` like every
other Omarchy plugin.

## Settings

| key | default | what |
| --- | --- | --- |
| `keybind` | `SUPER + SHIFT + C` | toggle chill on the current workspace (empty = no key) |
| `inset` | `10` | shrink per side, percent of the window's own size |
| `size` | `72` | newcomer size, percent of the work area |
| `rounding` | `14` | corner radius of chilled windows |
| `edge`, `gap` | `36`, `16` | flocking: margin from the screen edges, breathing room from other windows |
| `adopt` | `true` | a window opened on a chilled workspace floats in |
| `convert` | `true` | a window moved across the chill line converts |
| `auto` | `false` | a workspace chills itself while it holds at most `autoMax` windows |
| `autoMax` | `3` | how many windows a workspace may hold and still chill itself |
| `hide` | `true` | bind the hide and restore keys |
| `keyHide`, `keyRestore` | `SUPER + H`, `SUPER + SHIFT + H` | the hide and restore keys |
| `notify` | `true` | desktop notification on toggle |
| `hideWhenIdle` | `false` | show the sofa only while the workspace is chilled |

## Scripting

```bash
hyprctl eval 'chillmode.toggle()'      # current workspace
hyprctl eval 'chillmode.toggle(3)'     # workspace 3
hyprctl eval 'chillmode.hide()'        # hide the focused window (or "0x..." )
hyprctl eval 'chillmode.restore()'     # bring the most recently hidden one back
```

Every toggle emits a Hyprland custom event `custom>>chillmode <workspace> on|off`
on the event socket, and `chillmode.state()` returns `{ [workspace] = count }`.

## Known issue (not this plugin's)

On quickshell 0.3.1 / Omarchy 4.0.x, any write under `~/.config/omarchy/plugins/`
while the session is **locked** — installing, updating or editing any plugin —
can abort the shell (`FATAL: Tried to show lockscreen surfaces without active
lock`, Omarchy issue #8647 / quickshell #975, fixed upstream). The shell restarts
itself, but install and update this plugin with the screen unlocked.

## Requirements

Omarchy with the Lua-configured Hyprland (0.56+). Blur is switched on while a
workspace is chilled and put back afterwards.

**About the glass.** Chilled windows are held fully opaque at the compositor
level (see the comments in `chillmode.lua` for why), so the frosted look only
appears through pixels the *application itself* draws translucent — a terminal
with `alpha`/`opacity` below 1 in its own config (foot, alacritty, ghostty,
kitty all support this). Opaque apps such as browsers get the inset floating
layout, soft corners and shadows, without the glass. The screenshots above use
foot at alpha 0.76 (dark) / 0.88 (light).

## License

MIT
