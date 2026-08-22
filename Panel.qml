import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "nwilkens.crossover"
  ipcTarget: "nwilkens.crossover"
  manageIpc: false

  property string focusSection: "header"
  property int peerIndex: 0
  property bool cursorActive: false
  property bool addingPeer: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool anyLinked: {
    for (var i = 0; i < crossover.peers.length; i++) {
      if (crossover.peers[i].active && crossover.peers[i].alive) return true
    }
    return false
  }
  readonly property color barIconColor: crossover.daemonRunning ? barForeground : Qt.darker(barForeground, 1.55)
  readonly property bool headerHasCursor: cursorActive && focusSection === "header" && crossover.installed
  readonly property var strangers: {
    var out = []
    for (var i = 0; i < crossover.incoming.length; i++) {
      var entry = crossover.incoming[i]
      var known = false
      for (var j = 0; j < crossover.peers.length; j++) {
        if (Model.isDrivenBy([entry], crossover.peers[j])) { known = true; break }
      }
      if (!known) out.push(entry)
    }
    return out
  }
  readonly property string installCommand: "sudo pacman -S lan-mouse"
  readonly property string setupHost: crossover.localAddress !== "" ? crossover.localAddress : "<this-machine-ip>"
  readonly property string macSetupCommand:
    "curl -fsSL https://raw.githubusercontent.com/nwilkens/omarchy-crossover/main/scripts/install-macos.sh | bash -s -- " + setupHost

  function ensureCursor() {
    if (!crossover.installed) { focusSection = "install"; return }
    if (crossover.pendingFingerprint !== "") { focusSection = "approve"; return }
    if (crossover.peers.length === 0 && focusSection === "peers") focusSection = "add"
    if (peerIndex >= crossover.peers.length) peerIndex = Math.max(0, crossover.peers.length - 1)
    if (peerIndex < 0) peerIndex = 0
  }

  function sectionOrder() {
    var order = ["header"]
    if (crossover.pendingFingerprint !== "") order.push("approve")
    if (crossover.peers.length > 0) order.push("peers")
    order.push("add")
    order.push("setup")
    order.push("identity")
    return order
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy === 0) return

    if (focusSection === "peers") {
      var next = peerIndex + dy
      if (next >= 0 && next < crossover.peers.length) {
        peerIndex = next
        scrollCursorIntoView()
        return
      }
    }

    var order = sectionOrder()
    var at = order.indexOf(focusSection)
    if (at < 0) at = 0
    var target = Math.max(0, Math.min(order.length - 1, at + dy))
    focusSection = order[target]
    if (focusSection === "peers") peerIndex = dy > 0 ? 0 : crossover.peers.length - 1
    scrollCursorIntoView()
  }

  function selectedPeer() {
    if (crossover.peers.length === 0) return null
    return crossover.peers[Math.max(0, Math.min(peerIndex, crossover.peers.length - 1))]
  }

  function activateCursor() {
    ensureCursor()
    switch (focusSection) {
      case "install": copyText(root.installCommand); break
      case "header": crossover.toggleDaemon(); break
      case "approve": crossover.authorize(crossover.pendingFingerprint, "crossover peer"); break
      case "peers":
        var peer = selectedPeer()
        if (peer) crossover.activate(peer.handle, !peer.active)
        break
      case "add": root.beginAddPeer(); break
      case "setup": copyText(root.macSetupCommand); break
      case "identity": copyText(crossover.fingerprint); break
    }
  }

  function beginAddPeer() {
    addingPeer = true
    cursorActive = true
    focusSection = "add"
    Qt.callLater(function() { hostField.forceActiveFocus() })
  }

  function commitAddPeer() {
    var value = String(hostField.text || "").trim()
    if (value === "") { cancelAddPeer(); return }
    crossover.addPeer(value)
    hostField.text = ""
    addingPeer = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function cancelAddPeer() {
    hostField.text = ""
    addingPeer = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function cyclePosition() {
    var peer = selectedPeer()
    if (!peer || focusSection !== "peers") return
    var order = ["left", "right", "top", "bottom"]
    var next = order[(order.indexOf(peer.position) + 1) % order.length]
    crossover.setPosition(peer.handle, next)
  }

  function copyText(text) {
    if (!text) return
    copyProcess.command = ["wl-copy", "--", String(text)]
    copyProcess.running = true
    crossover.actionStatus = "Copied"
  }

  function setPeerCursor(index) {
    cursorActive = true
    focusSection = "peers"
    peerIndex = index
    scrollCursorIntoView()
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    if (focusSection === "peers" && peerColumn && peerIndex >= 0 && peerIndex < peerColumn.children.length) {
      scrollItemIntoView(peerColumn.children[peerIndex])
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    // Reopening starts clean: a half-typed hostname left over from last time
    // is confusing and hides the row it replaced.
    addingPeer = false
    hostField.text = ""
    if (panelFlick) panelFlick.contentY = 0
    crossover.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: crossover
    settings: root.settings
  }

  SeamIndicator {
    position: crossover.enteredPosition
    enabled: root.setting("seamIndicator", true)
    glow: Color.accent
  }

  Process {
    id: copyProcess
    running: false
    command: []
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function start(): string { crossover.start(); return "ok" }
    function stop(): string { crossover.stop(); return "ok" }
    function status(): string { return crossover.summary }
    function fingerprint(): string { return crossover.fingerprint }
    function testSeam(position: string): string {
      crossover.flashSeam(position === "" ? "left" : position)
      return "ok"
    }
    // Support hook: everything needed to tell "not installed" apart from
    // "installed but the daemon will not stay up" without reading QML logs.
    function state(): string {
      return JSON.stringify({
        installed: crossover.installed,
        checked: crossover.checkedInstall,
        linked: crossover.linked,
        daemonRunning: crossover.daemonRunning,
        emulation: crossover.emulationEnabled,
        capture: crossover.captureEnabled,
        macKeyboard: crossover.macKeyboardState,
        virtualKeyboard: crossover.virtualKeyboardName,
        clipdInstalled: crossover.clipdInstalled,
        clipdRunning: crossover.clipdRunning,
        peers: crossover.peers.length,
        daemonFailures: crossover.daemonFailures,
        opened: root.opened,
        driving: crossover.incoming.length,
        unconfigured: root.strangers.length,
        wantDaemon: crossover.wantDaemon,
        autostart: crossover.autostart,
        socketPath: crossover.socketPath(),
        attempts: crossover.connectAttempts,
        socketError: crossover.socketError,
        error: crossover.lastError
      })
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        CrossoverIcon {
          anchors.centerIn: parent
          iconSize: Style.space(12)
          color: root.barIconColor
          linked: root.anyLinked
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) crossover.refresh()
      else if (buttonCode === Qt.MiddleButton) crossover.toggleDaemon()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the host field is open the panel's single-key shortcuts would
      // otherwise swallow every character typed into it.
      blocked: root.addingPeer
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.addingPeer ? root.cancelAddPeer() : root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onDeleteRequested: {
        var peer = root.selectedPeer()
        if (root.focusSection === "peers" && peer) crossover.deletePeer(peer.handle)
      }
      onTextKey: function(t) {
        if (root.addingPeer) return
        var key = String(t || "").toLowerCase()
        if (key === "r") crossover.refresh()
        else if (key === "p") root.cyclePosition()
        else if (key === "n") root.beginAddPeer()
        else if (key === "c") root.copyText(crossover.fingerprint)
        else if (key === "s") crossover.toggleDaemon()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool ringVisible: root.headerHasCursor
            function focusHero() {
              root.cursorActive = true
              root.focusSection = "header"
              if (panelFlick) panelFlick.contentY = 0
            }

            PanelHero {
              id: hero
              width: parent.width
              title: "Crossover"
              meta: crossover.installed ? crossover.summary : "lan-mouse not installed"
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: crossover.daemonRunning ? 1.0 : 0.5
              iconComponent: Component {
                CrossoverIcon {
                  iconSize: Style.font.display
                  color: root.foreground
                  linked: root.anyLinked
                }
              }

              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  visible: crossover.installed
                  checked: crossover.daemonRunning
                  busy: crossover.busy
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: crossover.toggleDaemon()

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: crossover.daemonRunning ? "Stop sharing" : "Start sharing"
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: crossover.actionStatus !== "" || crossover.lastError !== ""

            Text {
              width: parent.width
              text: crossover.actionStatus !== "" ? crossover.actionStatus : crossover.lastError
              color: crossover.lastError !== "" && crossover.actionStatus === "" ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            // Giving up stops the retry loop, so without this the only way back
            // would be restarting the shell.
            Row {
              spacing: Style.space(8)
              visible: crossover.daemonGaveUp || crossover.clipdGaveUp

              PanelActionButton {
                visible: crossover.daemonGaveUp
                iconText: "Retry sharing"
                tooltipText: "Start lan-mouse again"
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                bordered: true
                onClicked: crossover.retryDaemon()
              }

              PanelActionButton {
                visible: crossover.clipdGaveUp
                iconText: "Retry clipboard"
                tooltipText: "Start the clipboard helper again"
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                bordered: true
                onClicked: crossover.retryClipd()
              }
            }
          }

          // Missing dependency is a first-class state, not an error banner:
          // the plugin cannot install it (the shell never runs install hooks),
          // so the most useful thing it can do is hand over the command.
          CursorSurface {
            id: installCard
            visible: crossover.checkedInstall && !crossover.installed
            width: parent.width
            implicitHeight: installColumn.implicitHeight + Style.space(20)
            foreground: root.foreground
            hasCursor: root.cursorActive && root.focusSection === "install"
            bordered: true

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onEntered: { root.cursorActive = true; root.focusSection = "install" }
              onClicked: root.copyText(root.installCommand)
            }

            Column {
              id: installColumn
              width: parent.width - Style.space(20)
              anchors.centerIn: parent
              spacing: Style.space(6)

              Text {
                width: parent.width
                text: "Install lan-mouse to continue"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                width: parent.width
                text: root.installCommand
                color: root.dim
                font.family: Style.font.mono ? Style.font.mono : root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WrapAnywhere
              }
              Text {
                width: parent.width
                text: "Enter to copy the command"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // An unknown machine asking to connect is the one moment where a
          // wrong click hands a stranger the keyboard, so it gets the urgent
          // treatment and shows enough fingerprint to actually compare.
          CursorSurface {
            id: approveCard
            visible: crossover.pendingFingerprint !== ""
            width: parent.width
            implicitHeight: approveColumn.implicitHeight + Style.space(20)
            foreground: root.urgent
            accent: root.urgent
            hasCursor: root.cursorActive && root.focusSection === "approve"
            bordered: true

            Column {
              id: approveColumn
              width: parent.width - Style.space(20)
              anchors.centerIn: parent
              spacing: Style.space(8)

              Text {
                width: parent.width
                text: "A machine wants to connect"
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                width: parent.width
                text: Model.shortFingerprint(crossover.pendingFingerprint)
                color: root.foreground
                font.family: Style.font.mono ? Style.font.mono : root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WrapAnywhere
              }
              Text {
                width: parent.width
                text: "Approve only if this matches the fingerprint shown on that machine."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Row {
                spacing: Style.space(8)
                PanelActionButton {
                  iconText: "Approve"
                  tooltipText: "Trust this machine"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  bordered: true
                  onClicked: crossover.authorize(crossover.pendingFingerprint, "crossover peer")
                }
                PanelActionButton {
                  iconText: "Deny"
                  tooltipText: "Dismiss this request"
                  foreground: root.dim
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  bordered: true
                  onClicked: crossover.pendingFingerprint = ""
                }
              }
            }
          }

          PanelSectionHeader {
            visible: crossover.installed && crossover.peers.length > 0
            width: parent.width
            text: "Machines"
            foreground: root.dim
            fontFamily: root.fontFamily
          }

          Column {
            id: peerColumn
            width: parent.width
            spacing: Style.space(4)
            visible: crossover.installed

            Repeater {
              model: crossover.peers
              delegate: CursorSurface {
                id: peerRow
                required property var modelData
                required property int index

                readonly property bool driving: Model.isDrivenBy(crossover.incoming, modelData)

                width: peerColumn.width
                implicitHeight: Style.space(38)
                foreground: root.foreground
                hasCursor: root.cursorActive && root.focusSection === "peers" && root.peerIndex === index
                current: (modelData.active && modelData.alive) || driving

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.LeftButton | Qt.RightButton
                  onEntered: root.setPeerCursor(index)
                  onClicked: function(mouse) {
                    root.setPeerCursor(index)
                    if (mouse.button === Qt.RightButton) root.cyclePosition()
                    else crossover.activate(modelData.handle, !modelData.active)
                  }
                }

                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(8)

                  Rectangle {
                    width: Style.space(7)
                    height: width
                    radius: width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    // Green for a working link in either direction. A machine
                    // that is driving this screen is connected, whatever our
                    // own outgoing link to it is doing.
                    color: peerRow.driving || (peerRow.modelData.active && peerRow.modelData.alive)
                           ? Color.accent
                           : (peerRow.modelData.active ? root.urgent : root.dim)
                    opacity: peerRow.modelData.active || peerRow.driving ? 1 : 0.5
                  }

                  Text {
                    width: parent.width - Style.space(120)
                    anchors.verticalCenter: parent.verticalCenter
                    text: peerRow.modelData.label
                    color: root.foreground
                    elide: Text.ElideRight
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: peerRow.driving ? "driving" : peerRow.modelData.position
                    color: peerRow.driving ? Color.accent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }

          // A machine can drive this screen without ever being configured as a
          // peer here, so incoming connections that match nothing in the list
          // still get a row rather than being invisible.
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.strangers.length > 0

            PanelSectionHeader {
              width: parent.width
              text: "Driving this screen"
              foreground: root.dim
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.strangers
              delegate: Item {
                required property var modelData
                width: parent.width
                implicitHeight: Style.space(32)

                Rectangle {
                  id: strangerDot
                  width: Style.space(7)
                  height: width
                  radius: width / 2
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  color: Color.accent
                }

                Text {
                  anchors.left: strangerDot.right
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.label
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "not configured"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          Item {
            id: addRow
            visible: crossover.installed
            width: parent.width
            implicitHeight: root.addingPeer ? hostField.implicitHeight : Style.space(34)

            CursorSurface {
              anchors.fill: parent
              visible: !root.addingPeer
              foreground: root.foreground
              hasCursor: root.cursorActive && root.focusSection === "add"

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onEntered: { root.cursorActive = true; root.focusSection = "add" }
                onClicked: root.beginAddPeer()
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                text: "Add a machine"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            TextField {
              id: hostField
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: root.addingPeer
              placeholderText: "Hostname or IP address"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              onAccepted: root.commitAddPeer()
              Keys.onEscapePressed: root.cancelAddPeer()
            }
          }

          PanelSeparator { width: parent.width; visible: crossover.installed }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: crossover.installed

            StatusLine {
              width: parent.width
              label: "Mac keys"
              value: !crossover.macKeyboard ? "Off"
                     : crossover.macKeyboardState === "applied" ? "Cmd acts as Ctrl"
                     : crossover.macKeyboardState === "unsupported" ? "Compositor refused the rule"
                     : crossover.macKeyboardState === "armed" ? "Ready, waiting for input"
                     : "Starting"
              warn: crossover.macKeyboard && crossover.macKeyboardState === "unsupported"
            }

            StatusLine {
              width: parent.width
              label: "Clipboard"
              value: !crossover.clipboardSync ? "Off"
                     : !crossover.clipdInstalled ? "Helper not installed"
                     : crossover.clipdGaveUp ? "Helper keeps exiting"
                     : crossover.clipdRunning ? "Shared" : "Starting"
              warn: crossover.clipboardSync && (!crossover.clipdInstalled || crossover.clipdGaveUp)
            }

            StatusLine {
              width: parent.width
              label: "Emulation"
              value: crossover.emulationEnabled ? "Ready" : "Inactive"
            }
          }

          // The whole point of failure for a two-machine tool is the second
          // machine: someone installs the plugin and has no idea what to run
          // over there. This hands them the exact line, with this machine's
          // address already in it.
          CursorSurface {
            id: setupRow
            visible: crossover.installed
            width: parent.width
            implicitHeight: setupColumn.implicitHeight + Style.space(16)
            foreground: root.foreground
            hasCursor: root.cursorActive && root.focusSection === "setup"
            bordered: crossover.peers.length === 0

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onEntered: { root.cursorActive = true; root.focusSection = "setup" }
              onClicked: root.copyText(root.macSetupCommand)
            }

            Column {
              id: setupColumn
              width: parent.width - Style.space(20)
              anchors.centerIn: parent
              spacing: Style.space(3)

              Text {
                width: parent.width
                text: "Set up another machine"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                width: parent.width
                text: "Run this on the Mac you want to drive from:"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
              Text {
                width: parent.width
                text: root.macSetupCommand
                color: root.dim
                font.family: Style.font.mono ? Style.font.mono : root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WrapAnywhere
              }
              Text {
                width: parent.width
                text: "Click to copy"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                opacity: 0.8
              }
            }
          }

          CursorSurface {
            id: identityRow
            visible: crossover.installed && crossover.fingerprint !== ""
            width: parent.width
            implicitHeight: identityColumn.implicitHeight + Style.space(16)
            foreground: root.foreground
            hasCursor: root.cursorActive && root.focusSection === "identity"

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onEntered: { root.cursorActive = true; root.focusSection = "identity" }
              onClicked: root.copyText(crossover.fingerprint)
            }

            Column {
              id: identityColumn
              width: parent.width - Style.space(20)
              anchors.centerIn: parent
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: "This machine"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                width: parent.width
                text: Model.shortFingerprint(crossover.fingerprint)
                color: root.foreground
                font.family: Style.font.mono ? Style.font.mono : root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                text: "Click to copy the full fingerprint"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }
    }
  }

  component StatusLine: Item {
    property string label: ""
    property string value: ""
    property bool warn: false

    implicitHeight: Style.space(18)

    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: parent.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: parent.value
      color: parent.warn ? root.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      opacity: 0.9
    }
  }
}
