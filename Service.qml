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

  property int connectAttempts: 0
  readonly property bool wantLink: installed && socketPath() !== ""
  property bool bouncing: false
  property string socketError: ""
  property bool clipdInstalled: false
  property int clipdFailures: 0
  readonly property bool clipdRunning: clipdProcess.running
  // Three quick failures in a row means something is wrong that retrying will
  // not fix, usually the port already being held. Surface it instead of
  // respawning forever.
  readonly property bool clipdGaveUp: clipdFailures >= 3

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
    var socket = ipcLoader.item
    if (!socket) return false
    socket.write(Model.encodeRequest(name, value) + "\n")
    socket.flush()
    return true
  }

  function start() {
    if (!installed || daemonProcess.running) return
    lastError = ""
    actionStatus = "Starting"
    // Snapshot the keyboards Hyprland already knows so the virtual one the
    // daemon is about to create can be identified by difference.
    captureKeyboardsThen(function() {
      // Backend selection is a top-level flag, so it has to precede the
      // subcommand or lan-mouse exits with a usage error.
      daemonProcess.command = ["lan-mouse", "--emulation-backend", root.emulationBackend, "daemon"]
      daemonProcess.running = true
    })
  }

  function stop() {
    actionStatus = "Stopping"
    daemonProcess.running = false
    dropLink()
    watchdogTimer.stop()
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

  function noteTraffic() {
    if (!linked) {
      linked = true
      actionStatus = ""
      socketError = ""
      // Ask for a full picture the moment the link comes up; the daemon only
      // volunteers state it happens to be changing.
      Qt.callLater(function() { root.refresh() })
    }
    bouncing = false
    watchdogTimer.restart()
  }

  function dropLink() {
    linked = false
    peers = []
    captureEnabled = false
    emulationEnabled = false
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
  property string _clipdStderr: ""

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
    if (!clipboardSync || !clipdInstalled || clipdProcess.running || clipdGaveUp) return
    clipdProcess.command = [clipdBinary(), "run", "--peer-config",
                            Quickshell.env("HOME") + "/.config/lan-mouse/config.toml"]
    clipdProcess.running = true
  }

  function stopClipd() {
    clipdProcess.running = false
  }

  function retryClipd() {
    clipdFailures = 0
    startClipd()
  }

  function clipdBinary() {
    return Quickshell.env("HOME") + "/.cargo/bin/crossover-clipd"
  }

  onMacKeyboardChanged: applyMacKeyboard()
  onClipboardSyncChanged: clipboardSync ? retryClipd() : stopClipd()

  Component.onCompleted: {
    whichProcess.command = ["which", "lan-mouse"]
    whichProcess.running = true
    clipdWhichProcess.command = ["test", "-x", clipdBinary()]
    clipdWhichProcess.running = true
    refreshMonitors()
  }

  // Quickshell 0.3 never emits connectionStateChanged, not even on a
  // successful connect, and a Socket whose `connected` is flipped after
  // creation does not reliably attempt the connection. A socket that connects
  // on creation does work, so each attempt gets a brand new Socket and link
  // state is derived from traffic rather than from the socket's property.
  Loader {
    id: ipcLoader
    active: root.wantLink && !root.bouncing

    sourceComponent: Component {
      Socket {
        path: root.socketPath()
        connected: true

        onError: function(error) { root.socketError = "socket error " + error }

        parser: SplitParser {
          onRead: function(line) {
            root.noteTraffic()
            root.handleEvent(line)
          }
        }
      }
    }
  }

  // Destroying and recreating the socket is what retries the connection. The
  // daemon usually needs a moment to bind after being started.
  Timer {
    id: retryTimer
    interval: 900
    repeat: true
    running: root.wantLink && !root.linked
    onTriggered: {
      if (root.bouncing) root.connectAttempts++
      root.bouncing = !root.bouncing
    }
  }

  // lan-mouse answers Sync with a full state dump, which doubles as the
  // heartbeat the watchdog needs to tell a live link from a dead one.
  Timer {
    id: heartbeatTimer
    interval: 8000
    repeat: true
    running: root.linked
    onTriggered: root.request("Sync")
  }

  Timer {
    id: watchdogTimer
    interval: 24000
    repeat: false
    onTriggered: root.dropLink()
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
      // The reconnect timer attaches to an already-running daemon on its own;
      // autostart only has to cover the case where nothing is running yet.
      if (root.installed && root.autostart) autostartTimer.start()
    }
  }

  Timer {
    id: autostartTimer
    interval: 1200
    onTriggered: if (!root.linked && !daemonProcess.running) root.start()
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
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "") root._clipdStderr = message.split("\n").pop()
      }
    }
    onExited: function(exitCode) {
      if (exitCode === 0 || exitCode === 143) return
      root.clipdFailures++
      if (root.clipdGaveUp) {
        root.lastError = root._clipdStderr !== ""
          ? "clipboard sync: " + root._clipdStderr
          : "clipboard sync keeps exiting (code " + exitCode + ")"
      }
    }
  }

  // Keeps the clipboard helper alive alongside the daemon. It is a separate
  // process precisely so a clipboard problem cannot take input sharing down.
  Timer {
    id: clipdSupervisor
    interval: 4000
    repeat: true
    running: root.clipboardSync && root.clipdInstalled && root.daemonRunning && !root.clipdGaveUp
    onTriggered: root.startClipd()
  }
}
