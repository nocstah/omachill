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
  // A service gets no `settings` of its own: the widget's entry has to be
  // found in the shell's config (bar.layout.<section>[] first, then
  // plugins[]). WHERE that config can be read depends on how much of the shell
  // this plugin is handed, and an installed plugin is handed very little:
  //
  //   shell.shellConfig   the whole config -- first-party services only
  //   shell.barConfig     what an installed plugin's scoped shell exposes
  //                       (services/PluginShellApi.qml has no shellConfig at
  //                       all): the `bar` object, and only re-assigned from
  //                       syncPluginApis(), which a settings write does NOT
  //                       trigger -- so it is a snapshot, not a live view
  //   shell.json          the file `omarchy bar set` rewrites; watched below
  //
  // Until 1.3.0 only the first was read, so on an installed plugin entryFor()
  // always returned null and EVERY option silently kept its manifest default.
  // It went unnoticed for as long as the stored values happened to be the
  // defaults. The file is the one source that is always both readable and
  // current, so it is consulted before the snapshot.
  function entryIn(config) {
    if (!config) return null
    // A whole shell config, or just its `bar` object (shell.barConfig).
    const bar = config.bar && typeof config.bar === "object" ? config.bar : config
    const layout = bar && bar.layout ? bar.layout : {}
    const sections = ["left", "center", "right"]
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
  function entryFor() {
    return entryIn(shell ? shell.shellConfig : null)
      || entryIn(fileConfig)
      || entryIn(shell ? shell.barConfig : null)
  }

  // shell.json as it is on disk. `omarchy bar set` (the panel writes through
  // it) rewrites the whole file, so watching it catches every settings change
  // whatever the shell hands this service.
  property var fileConfig: null
  FileView {
    id: shellConfigFile
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      let parsed = null
      try { parsed = JSON.parse(text()) } catch (e) { parsed = null }
      root.fileConfig = parsed
    }
    onLoadFailed: root.fileConfig = null
    onFileChanged: reload()
  }
  // The first injection stays with onManifestChanged below -- the file loads
  // before `manifest` is assigned, and an inject from here would run with the
  // manifest defaults still standing in. `lastOpts` empty means that first
  // injection has not happened yet.
  onFileConfigChanged: {
    if (!enginePath || !lastOpts) return
    if (luaOpts(readSettings()) !== lastOpts) inject()
  }

  // shell.json holds what `omarchy bar set` was given: a bare `true`/`45`
  // arrives as the string "true"/"45" (only `--json` stores typed values),
  // and Boolean("false") is true. Read both shapes.
  function asBool(v, fb) {
    if (v === undefined || v === null) return fb
    if (typeof v === "boolean") return v
    const t = String(v).trim().toLowerCase()
    if (t === "true" || t === "1" || t === "on" || t === "yes") return true
    if (t === "false" || t === "0" || t === "off" || t === "no" || t === "") return false
    return fb
  }
  function asNum(v, fb) { const n = Number(v); return isFinite(n) ? n : fb }

  function readSettings() {
    const d = manifest && manifest.barWidget && manifest.barWidget.defaults ? manifest.barWidget.defaults : {}
    const e = entryFor() || {}
    function pick(k, fb) { return e[k] !== undefined && e[k] !== null ? e[k] : (d[k] !== undefined ? d[k] : fb) }
    return {
      keybind: String(pick("keybind", "SUPER + SHIFT + C")),
      keyHide: String(pick("keyHide", "SUPER + H")),
      keyRestore: String(pick("keyRestore", "SUPER + SHIFT + H")),
      hide: asBool(pick("hide", true), true),
      edge: asNum(pick("edge", 36), 36),
      gap: asNum(pick("gap", 16), 16),
      adopt: asBool(pick("adopt", true), true),
      convert: asBool(pick("convert", true), true),
      auto: asBool(pick("auto", false), false),
      autoMax: asNum(pick("autoMax", 3), 3),
      inset: asNum(pick("inset", 10), 10) / 100,
      size: asNum(pick("size", 72), 72) / 100,
      rounding: asNum(pick("rounding", 14), 14),
      notify: asBool(pick("notify", true), true),
    }
  }

  function luaString(s) {
    return "\"" + String(s).replace(/\\/g, "\\\\").replace(/"/g, "\\\"").replace(/\n/g, " ") + "\""
  }

  function luaOpts(s) {
    return "CHILLMODE_OPTS = { keybind = " + luaString(s.keybind)
      + ", key_hide = " + luaString(s.keyHide) + ", key_restore = " + luaString(s.keyRestore)
      + ", hide = " + (s.hide ? "true" : "false") + ", edge = " + s.edge + ", gap = " + s.gap
      + ", adopt = " + (s.adopt ? "true" : "false") + ", convert = " + (s.convert ? "true" : "false")
      + ", auto = " + (s.auto ? "true" : "false") + ", auto_max = " + s.autoMax
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
