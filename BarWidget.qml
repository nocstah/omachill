// Omachill — bar widget. A sofa that lights up (theme blue) while the workspace
// shown on THIS monitor is chilled; click to chill / tile back.
//
// State comes from the engine: `custom>>chillmode <ws> on|off` events on the
// Hyprland socket trigger a refresh, and the refresh itself just counts
// "chillmode" tags in `hyprctl clients -j` (the tag is the engine's only
// state, so this can never disagree with it).
import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "io.github.nocstah.omachill"

  readonly property bool hideWhenIdle: setting("hideWhenIdle", false) === true

  // The theme's blue, read straight from the active theme's colors.toml the
  // same way qs.Commons Color reads its keys (Color itself only exposes
  // foreground/accent/urgent/muted). Fallbacks: explicit `blue`, else ANSI
  // `color4` (the conventional blue), else the theme accent, else a fixed
  // blue. Re-read whenever Color's base palette changes — that is the signal
  // that a theme switch just re-parsed the same file.
  property color themeBlue: "#3b82f6"
  function parseThemeBlue(raw) {
    const lines = String(raw || "").split("\n")
    let blue = "", c4 = ""
    for (let i = 0; i < lines.length; i++) {
      const m = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (!m) continue
      if (m[1] === "blue") blue = m[2]
      else if (m[1] === "color4") c4 = m[2]
    }
    themeBlue = blue || c4 || (Color.accent ? String(Color.accent) : "#3b82f6")
  }
  FileView {
    id: themeColorsFile
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: false
    printErrors: false
    onLoaded: root.parseThemeBlue(text())
    onLoadFailed: root.parseThemeBlue("")
  }
  Connections {
    target: Color
    function onAccentChanged() { themeColorsFile.reload() }
    function onForegroundChanged() { themeColorsFile.reload() }
  }

  // { workspaceName: chilledWindowCount }
  property var chilled: ({})

  readonly property var monitor: {
    const vals = Hyprland.monitors.values
    for (let i = 0; i < vals.length; i++) {
      if (vals[i] && String(vals[i].name) === String(Screen.name)) return vals[i]
    }
    return null
  }
  readonly property var workspace: monitor ? monitor.activeWorkspace : Hyprland.focusedWorkspace
  readonly property string wsName: workspace ? String(workspace.name) : ""
  readonly property int wsId: workspace ? Number(workspace.id) : 0
  readonly property int count: wsName && chilled[wsName] ? Number(chilled[wsName]) : 0
  readonly property bool active: count > 0
  readonly property bool shown: active || !hideWhenIdle

  implicitWidth: shown ? button.implicitWidth : 0
  implicitHeight: shown ? button.implicitHeight : 0
  visible: shown

  function refresh() {
    if (clientsProc.running) return
    clientsProc.running = true
  }

  function toggle() {
    if (!wsId) return
    // Util.shellQuote, not bar.shellQuote: the bar README documents the
    // latter, but Bar.qml (Omarchy 4.0.x) has no such function — the click
    // died with "Property 'shellQuote' ... is not a function".
    root.bar.run("hyprctl eval " + Util.shellQuote("chillmode.toggle(" + wsId + ")"))
  }

  Process {
    id: clientsProc
    running: false
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector {
      id: clientsOut
      waitForEnd: true
      onStreamFinished: {
        const next = {}
        try {
          const list = JSON.parse(String(clientsOut.text || "[]"))
          for (let i = 0; i < list.length; i++) {
            const c = list[i]
            const tags = Array.isArray(c.tags) ? c.tags : []
            let hit = false
            for (let t = 0; t < tags.length; t++) {
              if (String(tags[t]).replace(/\*$/, "") === "chillmode") { hit = true; break }
            }
            if (!hit || !c.workspace) continue
            const k = String(c.workspace.name)
            next[k] = (next[k] || 0) + 1
          }
        } catch (e) {
          console.warn("[omachill] clients parse failed: " + e)
        }
        root.chilled = next
      }
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      const n = String(event.name)
      if (n === "custom") {
        if (String(event.data || "").indexOf("chillmode") === 0) root.refresh()
      } else if (n === "configreloaded" || n === "closewindow" || n === "movewindowv2" || n === "workspacev2" || n === "focusedmonv2") {
        root.refresh()
      }
    }
  }

  Component.onCompleted: refresh()

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰒹"  // nf-md-sofa
    active: root.active
    activeColor: root.themeBlue
    tooltipText: root.active
      ? "Chill mode on workspace " + root.wsName + " (" + root.count + (root.count === 1 ? " window" : " windows") + ") — click to tile back"
      : "Click to chill workspace " + root.wsName
    onPressed: function(b) { root.toggle() }
  }
}
