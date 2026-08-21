import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Owns everything stateful: the lan-mouse daemon's lifecycle, its IPC socket,
// the Hyprland keyboard translation, and the clipboard sidecar. The panel is a
// pure view over these properties.
Item {
  id: root

  property var settings: ({})

  readonly property bool macKeyboard: setting("macKeyboard", true)
  readonly property bool clipboardSync: setting("clipboardSync", true)
  readonly property bool autostart: setting("autostart", true)
  readonly property string emulationBackend: String(setting("emulationBackend", "wlroots"))

  property bool installed: false
  property bool checkedInstall: false
  property bool linked: false
  property var peers: []
  property bool captureEnabled: false
  property bool emulationEnabled: false
  property string fingerprint: ""
  property var authorized: ({})
  property string pendingFingerprint: ""
  property string lastError: ""
  property string actionStatus: ""
  property var monitors: []

  // Set by DeviceEntered and cleared on a timer. The indicator watches this
  // rather than the peer list because entering is an event, not a state.
  property string enteredPosition: ""
  property string enteredPeer: ""

  // "off" while disabled, "applied" once Hyprland confirms the remap landed on
  // the virtual keyboard, "unsupported" when the compositor ignored it.
  property string macKeyboardState: "off"
  property string virtualKeyboardName: ""
  property var keyboardsBeforeStart: []

  property bool clipdInstalled: false
  property bool clipdRunning: false

  readonly property bool daemonRunning: daemonProcess.running || linked
  readonly property string summary: Model.summarize(peers, captureEnabled, emulationEnabled)
  readonly property bool busy: daemonProcess.running && !linked

  // Fingerprint to last-seen address, needed because DeviceEntered identifies
  // the crossing peer by fingerprint while peers are tracked by handle.
  property var fingerprintAddrs: ({})

  signal crossed(string position, string peer)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function socketPath() {
    var dir = Quickshell.env("XDG_RUNTIME_DIR")
    if (!dir) return ""
    return dir + "/lan-mouse-socket.sock"
  }

  function pluginDir() {
    var home = Quickshell.env("HOME")
    return home + "/.config/omarchy/plugins/nwilkens.crossover"
  }

  function request(name, value) {
    if (!ipc.connected) return false
    ipc.write(Model.encodeRequest(name, value) + "\n")
    ipc.flush()
    return true
  }

  function start() {
    if (!installed || daemonProcess.running) return
    lastError = ""
    actionStatus = "Starting"
    // Snapshot the keyboards Hyprland already knows so the virtual one the
    // daemon is about to create can be identified by difference.
    captureKeyboardsThen(function() {
      daemonProcess.command = ["lan-mouse", "daemon", "--emulation-backend", root.emulationBackend]
      daemonProcess.running = true
      reconnectTimer.start()
    })
  }

  function stop() {
    actionStatus = "Stopping"
    daemonProcess.running = false
    ipc.connected = false
    linked = false
    peers = []
    captureEnabled = false
    emulationEnabled = false
    macKeyboardState = "off"
    virtualKeyboardName = ""
    stopClipd()
  }

  function toggleDaemon() {
    if (daemonRunning) stop()
    else start()
  }

  function addPeer() { request("Create") }
  function deletePeer(handle) { request("Delete", handle) }
  function activate(handle, on) { request("Activate", [handle, on === true]) }

  function setPosition(handle, position) {
    request("UpdatePosition", [handle, Model.normalizePosition(position)])
    request("SaveConfiguration")
  }

  function setHostname(handle, hostname) {
    var value = String(hostname || "").trim()
    request("UpdateHostname", [handle, value === "" ? null : value])
    request("ResolveDns", handle)
    request("SaveConfiguration")
  }

  function setFixIps(handle, ips) {
    request("UpdateFixIps", [handle, ips])
    request("SaveConfiguration")
  }

  function authorize(fp, description) {
    if (!Model.isValidFingerprint(fp)) {
      lastError = "Refused a malformed fingerprint"
      return
    }
    request("AuthorizeKey", [String(description || "crossover"), String(fp)])
    request("SaveConfiguration")
    if (pendingFingerprint === fp) pendingFingerprint = ""
  }

  function revoke(fp) {
    request("RemoveAuthorizedKey", String(fp))
    request("SaveConfiguration")
  }

  function enableCapture() { request("EnableCapture") }
  function enableEmulation() { request("EnableEmulation") }

  function refresh() {
    request("Enumerate", [])
    request("Sync")
    refreshMonitors()
  }

  function handleEvent(line) {
    var event = Model.decodeEvent(line)
    if (!event) return

    switch (event.kind) {
      case "Enumerate":
        var list = []
        var raw = event.value || []
        for (var i = 0; i < raw.length; i++) {
          var peer = Model.decodePeer(raw[i])
          if (peer) list.push(peer)
        }
        peers = list
        break
      case "Created":
      case "State":
        peers = Model.upsertPeer(peers, Model.decodePeer(event.value))
        break
      case "Deleted":
        peers = Model.removePeer(peers, event.value)
        break
      case "CaptureStatus":
        captureEnabled = Model.statusToBool(event.value)
        break
      case "EmulationStatus":
        emulationEnabled = Model.statusToBool(event.value)
        // The virtual keyboard only exists once emulation is live, so this is
        // the earliest moment the remap can be applied.
        if (emulationEnabled) identifyVirtualKeyboard()
        break
      case "PublicKeyFingerprint":
        fingerprint = String(event.value || "")
        break
      case "AuthorizedUpdated":
        authorized = event.value || ({})
        break
      case "ConnectionAttempt":
        var attempt = event.value || {}
        if (Model.isValidFingerprint(attempt.fingerprint)) pendingFingerprint = String(attempt.fingerprint)
        break
      case "DeviceConnected":
        var connected = event.value || {}
        if (connected.fingerprint && connected.addr) {
          var map = Object.assign({}, fingerprintAddrs)
          map[String(connected.fingerprint)] = String(connected.addr)
          fingerprintAddrs = map
        }
        break
      case "DeviceEntered":
        var entered = event.value || {}
        if (entered.addr && entered.fingerprint) {
          var addrs = Object.assign({}, fingerprintAddrs)
          addrs[String(entered.fingerprint)] = String(entered.addr)
          fingerprintAddrs = addrs
        }
        noteCrossing(entered)
        break
      case "IncomingDisconnected":
        break
      case "PortChanged":
        var port = event.value || []
        if (Array.isArray(port) && port[1]) lastError = String(port[1])
        break
      case "Error":
        lastError = String(event.value || "")
        break
      case "Malformed":
        // A single unparseable line must not take the link down.
        break
    }
  }

  function noteCrossing(entered) {
    var match = Model.findPeerByFingerprint(peers, fingerprintAddrs, String(entered.fingerprint || ""))
    // The peer sends the edge it left from, so this screen is entered on the
    // opposite side.
    enteredPosition = Model.oppositePosition(entered.pos)
    enteredPeer = match ? match.label : Model.stripPort(String(entered.addr || ""))
    crossed(enteredPosition, enteredPeer)
    crossingTimer.restart()
  }

  function captureKeyboardsThen(next) {
    root._afterDevices = next
    devicesProcess.mode = "snapshot"
    devicesProcess.command = ["hyprctl", "-j", "devices"]
    devicesProcess.running = true
  }
  property var _afterDevices: null

  function identifyVirtualKeyboard() {
    devicesProcess.mode = "identify"
    devicesProcess.command = ["hyprctl", "-j", "devices"]
    devicesProcess.running = true
  }

  function parseKeyboards(text) {
    try {
      var data = JSON.parse(String(text || "{}"))
      return Array.isArray(data.keyboards) ? data.keyboards : []
    } catch (e) {
      return []
    }
  }

  function applyMacKeyboard() {
    if (virtualKeyboardName === "") return
    if (!macKeyboard) {
      keywordProcess.mode = "clear"
      keywordProcess.command = ["hyprctl", "keyword",
                                "device[" + virtualKeyboardName + "]:kb_options", ""]
      keywordProcess.running = true
      macKeyboardState = "off"
      return
    }
    keywordProcess.mode = "apply"
    keywordProcess.command = ["hyprctl", "keyword",
                              "device[" + virtualKeyboardName + "]:kb_options",
                              "ctrl:swap_lwin_lctl"]
    keywordProcess.running = true
  }

  function verifyMacKeyboard() {
    devicesProcess.mode = "verify"
    devicesProcess.command = ["hyprctl", "-j", "devices"]
    devicesProcess.running = true
  }

  function refreshMonitors() {
    monitorsProcess.command = ["hyprctl", "-j", "monitors"]
    monitorsProcess.running = true
  }

  function startClipd() {
    if (!clipboardSync || !clipdInstalled || clipdProcess.running) return
    clipdProcess.command = [clipdBinary(), "--peer-config", Quickshell.env("HOME") + "/.config/lan-mouse/config.toml"]
    clipdProcess.running = true
    clipdRunning = true
  }

  function stopClipd() {
    clipdProcess.running = false
    clipdRunning = false
  }

  function clipdBinary() {
    return Quickshell.env("HOME") + "/.cargo/bin/crossover-clipd"
  }

  onMacKeyboardChanged: applyMacKeyboard()
  onClipboardSyncChanged: clipboardSync ? startClipd() : stopClipd()

  Component.onCompleted: {
    whichProcess.command = ["which", "lan-mouse"]
    whichProcess.running = true
    clipdWhichProcess.command = ["test", "-x", clipdBinary()]
    clipdWhichProcess.running = true
    refreshMonitors()
  }

  Socket {
    id: ipc
    path: root.socketPath()
    connected: false

    onConnectionStateChanged: {
      root.linked = connected
      if (connected) {
        root.actionStatus = ""
        reconnectTimer.stop()
        root.refresh()
      } else {
        root.peers = []
        root.captureEnabled = false
        root.emulationEnabled = false
        if (root.installed) reconnectTimer.start()
      }
    }

    parser: SplitParser {
      onRead: function(line) { root.handleEvent(line) }
    }
  }

  // The daemon may take a moment to bind its socket, and it may be restarted
  // out from under us by the user, so reconnection is unconditional rather
  // than tied to our own start().
  Timer {
    id: reconnectTimer
    interval: 1000
    repeat: true
    running: false
    onTriggered: {
      if (ipc.connected) { stop(); return }
      if (!root.installed) { stop(); return }
      ipc.connected = true
    }
  }

  Timer {
    id: crossingTimer
    interval: 1400
    onTriggered: {
      root.enteredPosition = ""
      root.enteredPeer = ""
    }
  }

  Timer {
    id: statusClearTimer
    interval: 4000
    running: root.actionStatus !== ""
    onTriggered: root.actionStatus = ""
  }

  Process {
    id: whichProcess
    running: false
    command: []
    onExited: function(exitCode) {
      root.installed = exitCode === 0
      root.checkedInstall = true
      if (root.installed) {
        // Attach to an already-running daemon before deciding to start one.
        ipc.connected = true
        if (root.autostart) autostartTimer.start()
      }
    }
  }

  Timer {
    id: autostartTimer
    interval: 1200
    onTriggered: if (!ipc.connected && !daemonProcess.running) root.start()
  }

  Process {
    id: daemonProcess
    running: false
    command: []
    onExited: function(exitCode) {
      root.linked = false
      if (exitCode !== 0 && exitCode !== 143) root.lastError = "lan-mouse exited with code " + exitCode
      root.actionStatus = ""
    }
  }

  Process {
    id: devicesProcess
    property string mode: "snapshot"
    running: false
    command: []
    stdout: StdioCollector {
      id: devicesStdout
      waitForEnd: true
      onStreamFinished: {
        var keyboards = root.parseKeyboards(text)
        if (devicesProcess.mode === "snapshot") {
          root.keyboardsBeforeStart = keyboards.map(function(k) { return String(k.name || "") })
          if (root._afterDevices) {
            var next = root._afterDevices
            root._afterDevices = null
            next()
          }
        } else if (devicesProcess.mode === "identify") {
          for (var i = 0; i < keyboards.length; i++) {
            var name = String(keyboards[i].name || "")
            if (name === "") continue
            if (root.keyboardsBeforeStart.indexOf(name) < 0) {
              root.virtualKeyboardName = name
              root.applyMacKeyboard()
              return
            }
          }
        } else if (devicesProcess.mode === "verify") {
          for (var j = 0; j < keyboards.length; j++) {
            if (String(keyboards[j].name || "") !== root.virtualKeyboardName) continue
            var rules = String(keyboards[j].rules || "") + " " + String(keyboards[j].active_keymap || "")
            // Hyprland honours per-device xkb options for some virtual
            // keyboards and silently keeps the client-supplied keymap for
            // others, so success is only claimed when it is observable.
            root.macKeyboardState = rules.indexOf("swap_lwin_lctl") >= 0 ? "applied" : "unsupported"
            return
          }
          root.macKeyboardState = "unsupported"
        }
      }
    }
  }

  Process {
    id: keywordProcess
    property string mode: "apply"
    running: false
    command: []
    onExited: function(exitCode) {
      if (keywordProcess.mode !== "apply") return
      if (exitCode !== 0) {
        root.macKeyboardState = "unsupported"
        return
      }
      root.verifyMacKeyboard()
    }
  }

  Process {
    id: monitorsProcess
    running: false
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(String(text || "[]"))
          root.monitors = Array.isArray(data) ? data : []
        } catch (e) {
          root.monitors = []
        }
      }
    }
  }

  Process {
    id: clipdWhichProcess
    running: false
    command: []
    onExited: function(exitCode) {
      root.clipdInstalled = exitCode === 0
      if (root.clipdInstalled && root.clipboardSync) root.startClipd()
    }
  }

  Process {
    id: clipdProcess
    running: false
    command: []
    onExited: function(exitCode) {
      root.clipdRunning = false
      if (exitCode !== 0 && exitCode !== 143) root.lastError = "clipboard sync exited with code " + exitCode
    }
  }
}
