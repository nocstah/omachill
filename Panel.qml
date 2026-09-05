// Omachill — the dropdown, opened with a right-click on the sofa. Two pages:
//   chill     — the workspace under the pointer's state with a toggle, every
//               chilled workspace with a "tile back", and the hidden windows
//               with a "restore" each (most recently hidden first)
//   settings  — every setting in manifest.json's schema, drawn by type
//               (toggle, slider, key binding shown with its CLI hint). A change
//               is written with `omarchy bar set`; the service re-injects the
//               engine on the spot, no reload.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.nocstah.omachill"
  ipcTarget: "io.github.nocstah.omachill"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  readonly property string pluginId: "io.github.nocstah.omachill"

  readonly property string wsName: hostWidget ? String(hostWidget.wsName || "") : ""
  readonly property int wsId: hostWidget ? Number(hostWidget.wsId || 0) : 0
  readonly property int wsCount: hostWidget ? Number(hostWidget.count || 0) : 0
  readonly property bool wsActive: wsCount > 0

  // ---- data from the widget: chilled workspaces, windows on the piles
  readonly property var chilledList: {
    const m = hostWidget && hostWidget.chilled ? hostWidget.chilled : {}
    const ids = hostWidget && hostWidget.chilledIds ? hostWidget.chilledIds : {}
    const out = []
    for (const k in m) out.push({ name: k, id: ids[k] !== undefined ? ids[k] : 0, count: Number(m[k]) })
    out.sort(function(a, b) { return String(a.name).localeCompare(String(b.name), undefined, { numeric: true }) })
    return out
  }
  // The engine's stack, oldest first; most recently hidden shown first, then
  // anything on a pile it never tracked.
  property var stackAddrs: []
  FileView {
    id: stackFile
    path: Quickshell.env("HOME") + "/.local/state/hypr-chill-hidden"
    watchChanges: true
    printErrors: false
    onLoaded: {
      const lines = String(text() || "").split("\n")
      const out = []
      for (let i = 0; i < lines.length; i++) { const a = lines[i].trim().split(/\s+/)[0]; if (a && a.indexOf("0x") === 0) out.push(a) }
      root.stackAddrs = out
    }
    onLoadFailed: root.stackAddrs = []
    onFileChanged: reload()
  }
  readonly property var hiddenList: {
    const wins = hostWidget && hostWidget.hiddenWindows ? hostWidget.hiddenWindows : []
    const byAddr = {}
    for (let i = 0; i < wins.length; i++) byAddr[String(wins[i].address)] = wins[i]
    const out = []
    const seen = {}
    for (let i = root.stackAddrs.length - 1; i >= 0; i--) {
      const a = root.stackAddrs[i]
      if (byAddr[a] && !seen[a]) { out.push(byAddr[a]); seen[a] = true }
    }
    for (let i = 0; i < wins.length; i++) { const a = String(wins[i].address); if (!seen[a]) { out.push(wins[i]); seen[a] = true } }
    return out
  }

  // ---- settings: the manifest's schema and defaults, overrides in `settings`
  property var manifest: ({})
  FileView {
    id: manifestFile
    path: String(Qt.resolvedUrl("manifest.json")).replace(/^file:\/\//, "")
    watchChanges: false
    printErrors: false
    onLoaded: { try { root.manifest = JSON.parse(text()) } catch (e) { root.manifest = {} } }
  }
  readonly property var schema: (manifest && manifest.barWidget && manifest.barWidget.schema) ? manifest.barWidget.schema : []
  readonly property var defaults: (manifest && manifest.barWidget && manifest.barWidget.defaults) ? manifest.barWidget.defaults : ({})
  function value(key) {
    const s = root.settings || {}
    if (s[key] !== undefined && s[key] !== null) return s[key]
    return root.defaults ? root.defaults[key] : undefined
  }
  // Booleans and numbers go typed (`--json`); a bare value is stored as a
  // string, and the service would read "false" as true.
  function setOption(key, v) {
    if (!root.bar) return
    const typed = typeof v === "boolean" || typeof v === "number"
    root.bar.run("omarchy bar set " + root.pluginId + " " + key + " " + Util.shellQuote(typed ? JSON.stringify(v) : String(v)) + (typed ? " --json" : ""))
  }
  function evalLua(code) {
    if (!root.bar) return
    root.bar.run("hyprctl eval " + Util.shellQuote(code))
  }
  readonly property color panelForeground: root.bar ? root.bar.foreground : Color.popups.text
  readonly property string keyHideText: String(root.value("keyHide") || "")

  property string page: "chill"

  function open() { root.controller.show(); stackFile.reload(); if (hostWidget && hostWidget.refresh) hostWidget.refresh() }
  function openFromHotkey() { open() }
  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(10)

        // ---- header
        Item {
          width: parent.width
          height: Math.max(titleCol.height, root.page === "chill" ? toggleButton.height : backButton.height)
          Column {
            id: titleCol
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            Text {
              text: root.page === "chill" ? "Chill mode" : "Chill settings"
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              text: root.page === "chill"
                ? (root.wsName
                    ? (root.wsActive
                        ? "Workspace " + root.wsName + " is chilled, " + root.wsCount + (root.wsCount === 1 ? " window" : " windows")
                        : "Workspace " + root.wsName + " is tiling")
                    : "No workspace on this monitor")
                : "Applied on the spot"
              color: Color.popups.text
              opacity: 0.6
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: Math.max(80, column.width - (root.page === "chill" ? toggleButton.width : backButton.width) - Style.space(12))
            }
          }
          Button {
            id: toggleButton
            visible: root.page === "chill"
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.wsActive ? "Tile back" : "Chill"
            foreground: root.panelForeground
            focusable: false
            onClicked: { if (hostWidget && hostWidget.toggle) hostWidget.toggle() }
          }
          PanelActionButton {
            id: backButton
            visible: root.page === "settings"
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰅁"
            tooltipText: "Back"
            foreground: root.panelForeground
            onClicked: root.page = "chill"
          }
        }

        PanelSeparator { width: parent.width }

        // =====================================================================
        // Chill page
        // =====================================================================
        Column {
          visible: root.page === "chill"
          width: parent.width
          spacing: Style.space(10)

          // ---- chilled workspaces
          Column {
            width: parent.width
            spacing: Style.space(2)
            PanelSectionHeader { text: "Chilled workspaces" }
            Text {
              visible: root.chilledList.length === 0
              text: "Nothing is chilled right now."
              color: Color.popups.text
              opacity: 0.6
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            Repeater {
              model: root.chilledList
              delegate: Item {
                required property var modelData
                width: column.width
                height: Math.max(wsText.height, wsButton.height) + Style.space(4)
                Text {
                  id: wsText
                  anchors.left: parent.left
                  anchors.right: wsButton.left
                  anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Workspace " + modelData.name + "  ·  " + modelData.count + (modelData.count === 1 ? " window" : " windows")
                  color: Color.popups.text
                  elide: Text.ElideRight
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }
                Button {
                  id: wsButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Tile back"
                  foreground: root.panelForeground
                  focusable: false
                  onClicked: root.evalLua("chillmode.toggle(" + (modelData.id ? String(modelData.id) : JSON.stringify("name:" + modelData.name)) + ")")
                }
              }
            }
          }

          // ---- hidden windows
          Column {
            width: parent.width
            spacing: Style.space(2)
            PanelSectionHeader { text: "Hidden windows" }
            Text {
              visible: root.hiddenList.length === 0
              text: root.keyHideText ? root.keyHideText + " hides the focused window; it comes back exactly where it was." : "No hidden windows."
              color: Color.popups.text
              opacity: 0.6
              width: parent.width
              wrapMode: Text.WordWrap
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            Repeater {
              model: root.hiddenList
              delegate: Item {
                required property var modelData
                width: column.width
                height: Math.max(hidCol.implicitHeight, hidButton.height) + Style.space(4)
                Column {
                  id: hidCol
                  anchors.left: parent.left
                  anchors.right: hidButton.left
                  anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(1)
                  Text {
                    text: String(modelData.title || modelData.class || modelData.address)
                    color: Color.popups.text
                    width: parent.width
                    elide: Text.ElideRight
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    text: String(modelData.class || "") + (modelData.pile ? "  ·  " + modelData.pile : "")
                    visible: text !== ""
                    color: Color.popups.text
                    opacity: 0.6
                    width: parent.width
                    elide: Text.ElideRight
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }
                Button {
                  id: hidButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Restore"
                  foreground: root.panelForeground
                  focusable: false
                  onClicked: { root.evalLua("chillmode.restore(" + JSON.stringify(String(modelData.address)) + ")"); root.close() }
                }
              }
            }
          }

          // ---- the way in
          Item {
            width: parent.width
            height: settingsButton.height
            PanelActionButton {
              id: settingsButton
              anchors.right: parent.right
              iconText: "󰒓"
              tooltipText: "Settings"
              foreground: root.panelForeground
              onClicked: root.page = "settings"
            }
          }
        }

        // =====================================================================
        // Settings page: one row per schema entry
        // =====================================================================
        Column {
          visible: root.page === "settings"
          width: parent.width
          spacing: Style.space(10)

          Repeater {
            model: root.schema
            delegate: Column {
              id: srow
              required property var modelData
              readonly property var e: modelData
              readonly property var v: root.value(modelData.key)
              // What the control shows between the write and the shell
              // handing the new value back: the value just chosen, so a
              // slider does not snap back meanwhile.
              property var pending: undefined
              onVChanged: pending = undefined
              readonly property var shown: pending !== undefined ? pending : v
              width: column.width
              spacing: Style.space(2)

              // ---- boolean
              Item {
                visible: srow.e.type === "boolean"
                width: parent.width
                height: visible ? Math.max(bCol.implicitHeight, bSwitch.implicitHeight) + Style.space(4) : 0
                Column {
                  id: bCol
                  anchors.left: parent.left
                  anchors.right: bSwitch.left
                  anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)
                  Text {
                    text: srow.e.label || srow.e.key
                    color: Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    text: srow.e.description || ""
                    visible: text !== ""
                    color: Color.popups.text
                    opacity: 0.6
                    width: parent.width
                    wrapMode: Text.WordWrap
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }
                ToggleSwitch {
                  id: bSwitch
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  checked: srow.shown === true
                  foreground: root.panelForeground
                  accent: Color.accent
                  onToggled: { const next = !(srow.shown === true); srow.pending = next; root.setOption(srow.e.key, next) }
                }
              }

              // ---- integer
              Column {
                visible: srow.e.type === "integer"
                width: parent.width
                spacing: Style.space(2)
                Item {
                  width: parent.width
                  height: iLabel.height
                  Text {
                    id: iLabel
                    anchors.left: parent.left
                    text: srow.e.label || srow.e.key
                    color: Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    anchors.right: parent.right
                    text: String(Math.round(iSlider.dragging ? iSlider.liveValue : Number(srow.shown)))
                    color: Color.accent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                }
                PanelSlider {
                  id: iSlider
                  bar: root.bar
                  width: parent.width
                  minimum: Number(srow.e.min !== undefined ? srow.e.min : 0)
                  maximum: Number(srow.e.max !== undefined ? srow.e.max : 100)
                  step: Number(srow.e.step !== undefined ? srow.e.step : 1)
                  integer: true
                  value: Number(srow.shown)
                  onReleased: function(x) { const n = Math.round(x); srow.pending = n; root.setOption(srow.e.key, n) }
                }
                Text {
                  text: srow.e.description || ""
                  visible: text !== ""
                  color: Color.popups.text
                  opacity: 0.6
                  width: parent.width
                  wrapMode: Text.WordWrap
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              // ---- string (the key bindings): shown, changed from the CLI
              Column {
                visible: srow.e.type === "string"
                width: parent.width
                spacing: Style.space(2)
                Item {
                  width: parent.width
                  height: sLabel.height
                  Text {
                    id: sLabel
                    anchors.left: parent.left
                    text: srow.e.label || srow.e.key
                    color: Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    anchors.right: parent.right
                    text: String(srow.shown === undefined ? "" : srow.shown)
                    color: Color.accent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                }
                Text {
                  text: (srow.e.description ? srow.e.description + " " : "") + "Change it with: omarchy bar set " + root.pluginId + " " + srow.e.key + " \"SUPER + …\""
                  color: Color.popups.text
                  opacity: 0.6
                  width: parent.width
                  wrapMode: Text.WordWrap
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }
      }
    }
  }
}
