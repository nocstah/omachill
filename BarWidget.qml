// Omachill — bar widget. A snowflake that lights up while the workspace
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
    root.bar.run("hyprctl eval " + root.bar.shellQuote("chillmode.toggle(" + wsId + ")"))
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
    text: "󰜗"
    active: root.active
    tooltipText: root.active
      ? "Chill mode on workspace " + root.wsName + " (" + root.count + (root.count === 1 ? " window" : " windows") + ") — click to tile back"
      : "Click to chill workspace " + root.wsName
    onPressed: function(b) { root.toggle() }
  }
}
