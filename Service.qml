// Omachill — service half. Keeps chillmode.lua loaded in the running
// Hyprland.
//
// A `hyprctl reload` rebuilds Hyprland's Lua state from the config files and
// nothing else: every runtime global, hook, bind and rule is gone, so an
// engine that was only ever injected cannot outlive a reload, and at session
// start several reloads fire before the shell's event socket is even
// connected (2026-09-02: shell said injected, compositor had no engine).
// The config therefore loads the engine itself:
//
//   ~/.config/hypr/omachill.lua       written here on every start and on
//                                     every settings change: the options,
//                                     then dofile(chillmode.lua). Removed
//                                     when this service goes away.
//   ~/.config/hypr/hyprland.lua       one guarded line appended once (marked
//                                     block), dofile()ing the loader if it
//                                     exists. That is the only edit ever
//                                     made to a user file.
//
//   shell start / plugin (re)load   -> write loader, ensure the include,
//                                      `hyprctl eval dofile(loader)` for
//                                      immediate effect (retry while
//                                      Hyprland is not ready)
//   any `hyprctl reload`            -> the config re-runs the loader; the
//                                      `configreloaded` event additionally
//                                      re-injects, which is a no-op in
//                                      effect (the engine is re-entrant)
//   widget settings change          -> rewrite the loader, inject again
//   plugin disabled / shell exit    -> chillmode.unload() (only our own
//                                      engine), loader removed
//
// The engine's only persistent state is the "chillmode" window tag, which
// lives in the compositor.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

Item {
  id: root
  visible: false

  // Injected by the shell after construction (see shell.qml ensureService).
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "io.github.nocstah.omachill"

  // Our own directory, resolved from this file's URL. Deliberately NOT from
  // manifest.__sourceDir: the shell assigns `manifest` after construction and
  // bindings on it have not re-evaluated when onManifestChanged fires, so a
  // path derived from it is still "" at the moment the first inject runs.
  readonly property string sourceDir: {
    const url = Qt.resolvedUrl(".").toString()
    return url.replace(/^file:\/\//, "").replace(/\/$/, "")
  }
  readonly property string enginePath: sourceDir + "/chillmode.lua"
  readonly property string loaderPath: Quickshell.env("HOME") + "/.config/hypr/omachill.lua"
  readonly property string hyprlandLua: Quickshell.env("HOME") + "/.config/hypr/hyprland.lua"

  property string lastOpts: ""
  property int attempts: 0
  property bool injected: false

  // One stamp per Service instance, handed to the engine and checked by the
  // unload below. When the shell hot-reloads this plugin (any write under
  // its directory), the old instance's detached `chillmode.unload()` races
  // the new instance's inject — and when it loses, it tears down the fresh
  // engine: no key, no bar toggle, and the next `hyprctl reload` hands
  // SUPER + SHIFT + C back to the Calendar webapp. Seen 2026-09-02. With the
  // stamp, a stale unload finds a newer engine and leaves it alone.
  readonly property string generation: String(Date.now()) + "-" + String(Math.floor(Math.random() * 1e9))

  // ---- settings -----------------------------------------------------------
  // A service gets no `settings`; read the widget's entry out of shell.json
  // (bar.layout.<section>[] first, then plugins[]) the way quickshell.spotify
  // does. Keys missing there fall back to the manifest defaults.
  function entryFor(config) {
    if (!config) return null
    const sections = ["left", "center", "right"]
    const layout = config.bar && config.bar.layout ? config.bar.layout : {}
    for (let s = 0; s < sections.length; s++) {
      const list = layout[sections[s]]
      if (!Array.isArray(list)) continue
      for (let i = 0; i < list.length; i++) {
        const e = list[i]
        if (e && (e.id === pluginId || e === pluginId)) return typeof e === "object" ? e : {}
      }
    }
    const plugins = Array.isArray(config.plugins) ? config.plugins : []
    for (let i = 0; i < plugins.length; i++) {
      const e = plugins[i]
      if (e && (e.id === pluginId || e === pluginId)) return typeof e === "object" ? e : {}
    }
    return null
  }

  function readSettings() {
    const d = manifest && manifest.barWidget && manifest.barWidget.defaults ? manifest.barWidget.defaults : {}
    const e = entryFor(shell ? shell.shellConfig : null) || {}
    function pick(k, fb) { return e[k] !== undefined && e[k] !== null ? e[k] : (d[k] !== undefined ? d[k] : fb) }
    return {
      keybind: String(pick("keybind", "SUPER + SHIFT + C")),
      keyHide: String(pick("keyHide", "SUPER + H")),
      keyRestore: String(pick("keyRestore", "SUPER + SHIFT + H")),
      inset: Number(pick("inset", 10)) / 100,
      size: Number(pick("size", 72)) / 100,
      rounding: Number(pick("rounding", 14)),
      notify: Boolean(pick("notify", true)),
    }
  }

  function luaString(s) {
    return "\"" + String(s).replace(/\\/g, "\\\\").replace(/"/g, "\\\"").replace(/\n/g, " ") + "\""
  }

  function luaOpts(s) {
    return "CHILLMODE_OPTS = { keybind = " + luaString(s.keybind)
      + ", key_hide = " + luaString(s.keyHide) + ", key_restore = " + luaString(s.keyRestore)
      + ", inset = " + s.inset + ", size = " + s.size + ", rounding = " + s.rounding
      + ", notify = " + (s.notify ? "true" : "false")
      + ", generation = " + luaString(generation) + " }"
  }

  // ---- injection ----------------------------------------------------------
  function shellQuote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

  // The loader Hyprland's config runs on every reload.
  function loaderText(opts) {
    return "-- Omachill (io.github.nocstah.omachill) — written by the shell plugin on\n"
      + "-- every start and settings change, removed when it is disabled. Loaded\n"
      + "-- from hyprland.lua so the chill-mode engine is re-created on every\n"
      + "-- `hyprctl reload`, which rebuilds Hyprland's Lua state from scratch.\n"
      + "-- Do not edit: settings live in the bar widget (shell.json).\n"
      + opts + "\n"
      + "local engine = " + luaString(enginePath) + "\n"
      + "local f = io.open(engine, \"r\")\n"
      + "if f then f:close() dofile(engine) end\n"
  }

  // One guarded include, appended once to the user's hyprland.lua.
  readonly property string includeMarker: ">>> io.github.nocstah.omachill"
  readonly property string includeBlock:
    "\n-- " + includeMarker + ": chill-mode engine, re-created on every reload (line managed by the plugin) >>>\n"
    + "do local p = os.getenv(\"HOME\") .. \"/.config/hypr/omachill.lua\"; local f = io.open(p, \"r\"); if f then f:close(); dofile(p) end end\n"
    + "-- <<< io.github.nocstah.omachill <<<\n"

  function inject() {
    if (!enginePath) return
    if (injectProc.running) { pending = true; return }
    const opts = luaOpts(readSettings())
    lastOpts = opts
    const script =
      "set -e; printf '%s' " + shellQuote(loaderText(opts)) + " > " + shellQuote(loaderPath) + "; "
      + "if [ -f " + shellQuote(hyprlandLua) + " ] && ! grep -qF " + shellQuote(includeMarker) + " " + shellQuote(hyprlandLua) + "; then "
      + "printf '%s' " + shellQuote(includeBlock) + " >> " + shellQuote(hyprlandLua) + "; fi; "
      + "exec hyprctl eval " + shellQuote("dofile(" + luaString(loaderPath) + ")")
    injectProc.command = ["bash", "-c", script]
    injectProc.running = true
  }

  property bool pending: false

  Process {
    id: injectProc
    running: false
    stdout: StdioCollector { id: injectOut; waitForEnd: true }
    onExited: function(code) {
      const out = String(injectOut.text || "").trim()
      if (code === 0 && out.indexOf("ok") === 0) {
        root.injected = true
        root.attempts = 0
      } else {
        root.injected = false
        root.attempts += 1
        console.warn("[omachill] inject failed (" + code + "): " + out)
        if (root.attempts < 20) retry.restart()
      }
      if (root.pending) { root.pending = false; root.inject() }
    }
  }

  // Hyprland can still be parsing its config when the shell comes up.
  Timer {
    id: retry
    interval: 1500
    repeat: false
    onTriggered: root.inject()
  }

  // manifest (and with it sourceDir) is assigned AFTER Component.onCompleted,
  // so the first injection is driven from here, not from onCompleted.
  // First injection once the shell has handed us `shell` (settings live in
  // shell.shellConfig). manifest arrives last, so it is the trigger.
  onManifestChanged: inject()

  // Settings edited in the widget (omarchy bar set) rewrite shell.json;
  // re-inject only when the resulting options actually differ.
  Connections {
    target: root.shell
    ignoreUnknownSignals: true
    function onShellConfigChanged() {
      if (!root.enginePath) return
      if (root.luaOpts(root.readSettings()) !== root.lastOpts) root.inject()
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      if (String(event.name) === "configreloaded") root.inject()
    }
  }

  // `omarchy-shell omachill status` / `omarchy-shell omachill inject`
  IpcHandler {
    target: "omachill"
    function status(): string {
      return JSON.stringify({ injected: root.injected, attempts: root.attempts, engine: root.enginePath, opts: root.lastOpts })
    }
    function inject(): string { root.inject(); return "ok" }
  }

  Component.onDestruction: {
    // Disable / remove / shell restart: leave the compositor as we found it
    // (minus the Calendar key the engine displaced — a `hyprctl reload`
    // brings that back). Only OUR engine, though: on a plugin hot-reload the
    // replacement instance may already have injected a newer one.
    // The loader goes too: a reload after this must not resurrect an engine
    // for a plugin that was disabled or removed.
    Quickshell.execDetached(["bash", "-c",
      "rm -f " + shellQuote(loaderPath) + "; exec hyprctl eval " + shellQuote(
        "if type(chillmode) == 'table' and chillmode.unload and chillmode.generation == "
        + luaString(generation) + " then chillmode.unload() end")])
  }
}
