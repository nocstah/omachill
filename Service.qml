// Omachill — service half. Puts chillmode.lua into the running Hyprland
// with `hyprctl eval` and keeps it there.
//
//   shell start / plugin (re)load   -> inject (retry while Hyprland is not ready)
//   Hyprland `configreloaded`       -> inject again (a reload wipes runtime
//                                      binds, hooks and window rules)
//   widget settings change          -> inject again with the new options
//                                      (the engine is re-entrant: it unloads
//                                      its previous registration first)
//   plugin disabled / shell exit    -> chillmode.unload()
//
// Nothing is written into ~/.config/hypr. The engine's only persistent state
// is the "chillmode" window tag, which lives in the compositor.
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

  property string lastOpts: ""
  property int attempts: 0
  property bool injected: false

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
      + ", inset = " + s.inset + ", size = " + s.size + ", rounding = " + s.rounding
      + ", notify = " + (s.notify ? "true" : "false") + " }"
  }

  // ---- injection ----------------------------------------------------------
  function inject() {
    if (!enginePath) return
    if (injectProc.running) { pending = true; return }
    const opts = luaOpts(readSettings())
    lastOpts = opts
    injectProc.command = ["hyprctl", "eval", opts + "; dofile(" + luaString(enginePath) + ")"]
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
    // brings that back).
    Quickshell.execDetached(["hyprctl", "eval",
      "if type(chillmode) == 'table' and chillmode.unload then chillmode.unload() end"])
  }
}
