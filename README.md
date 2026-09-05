# Omachill

Float every window on the current workspace **in place** — each pulled in a
little on all four sides (10 % by default), with soft corners and glass — and
press again to tile them back exactly where they were. A look, not a
re-layout: your arrangement is preserved, the visible change is the air around
each window. Plus macOS-style hide and restore: `SUPER + H` parks a window,
`SUPER + SHIFT + H` brings it back exactly where it was.

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
- **Reload-proof** — the `chillmode` window tag is the only state, so a
  Hyprland reload or a shell restart cannot lose track of what is chilled.

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
margin and gap, whether new windows join and moves convert, whether the hide
keys are bound, notifications, hide-when-idle. Changes apply on the spot. The
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
