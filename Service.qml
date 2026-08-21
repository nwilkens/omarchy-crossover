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

  // "off" when disabled, "armed" once the device rule is registered but the
  // virtual keyboard has not appeared yet, "applied" once Hyprland reports the
  // rule on the live device, "unsupported" if the compositor ignored it.
  property string macKeyboardState: "off"
  property string globalKbOptions: ""
  // Hyprland names virtual keyboards "hl-virtual-keyboard-<client>", and the
  // client here is always lan-mouse. Registering the rule by name means it
  // applies the moment the device appears, which matters because the device
  // only exists while a peer is actually sending input.
  readonly property string virtualKeyboardName: "hl-virtual-keyboard-lan-mouse"
  readonly property string macKeyOption: "ctrl:swap_lwin_lctl"

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
    // Backend selection is a top-level flag, so it has to precede the
    // subcommand or lan-mouse exits with a usage error.
    daemonProcess.command = ["lan-mouse", "--emulation-backend", root.emulationBackend, "daemon"]
    daemonProcess.running = true
    applyMacKeyboard()
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

  function keyboardOptions(withSwap) {
    var parts = []
    var base = String(globalKbOptions || "").split(",")
    for (var i = 0; i < base.length; i++) {
      var option = base[i].trim()
      if (option !== "" && option !== macKeyOption) parts.push(option)
    }
    if (withSwap) parts.push(macKeyOption)
    return parts.join(",")
  }

  // Hyprland 0.56 moved to a Lua config parser, and `hyprctl keyword` is
  // refused outright by it. Device rules go through hl.device instead.
  function applyMacKeyboard() {
    if (!installed) return
    var options = keyboardOptions(macKeyboard)
    var lua = 'hl.device({ name = "' + virtualKeyboardName + '", kb_options = "' + options + '" })'
    keywordProcess.mode = macKeyboard ? "apply" : "clear"
    keywordProcess.command = ["hyprctl", "eval", lua]
    keywordProcess.running = true
  }

  function verifyMacKeyboard() {
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
    kbOptionsProcess.command = ["hyprctl", "getoption", "input:kb_options"]
    kbOptionsProcess.running = true
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
    running: false
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var keyboards = root.parseKeyboards(text)
        for (var i = 0; i < keyboards.length; i++) {
          if (String(keyboards[i].name || "") !== root.virtualKeyboardName) continue
          var rules = String(keyboards[i].rules || "")
          // Only claim success when the compositor reports the rule on the
          // live device. Anything else is reported as not applied.
          root.macKeyboardState = rules.indexOf(root.macKeyOption) >= 0 ? "applied" : "unsupported"
          return
        }
        // The virtual keyboard only exists while a peer is sending input, so
        // its absence means the rule is registered and waiting, not broken.
        if (root.macKeyboard) root.macKeyboardState = "armed"
      }
    }
  }

  Process {
    id: keywordProcess
    property string mode: "apply"
    running: false
    command: []
    onExited: function(exitCode) {
      if (keywordProcess.mode !== "apply") {
        root.macKeyboardState = "off"
        return
      }
      if (exitCode !== 0) {
        root.macKeyboardState = "unsupported"
        return
      }
      root.verifyMacKeyboard()
    }
  }

  // The virtual keyboard comes and goes with the link, so the applied state is
  // re-checked rather than latched once.
  Timer {
    interval: 6000
    repeat: true
    running: root.macKeyboard && root.linked
    onTriggered: root.verifyMacKeyboard()
  }

  Process {
    id: kbOptionsProcess
    running: false
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // `hyprctl getoption` prints "str: <value>" followed by "set: <bool>".
        var match = String(text || "").match(/str:\s*(.*)/)
        root.globalKbOptions = match ? String(match[1]).trim() : ""
        root.applyMacKeyboard()
      }
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
