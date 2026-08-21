.pragma library

// lan-mouse speaks newline-delimited JSON of serde's externally tagged enum
// representation over its unix socket. Unit variants arrive as bare strings,
// single-field variants as {"Name": value}, multi-field tuple variants as
// {"Name": [a, b]}, and struct variants as {"Name": {...}}. Everything below
// exists to keep that shape from leaking into the QML.

var POSITIONS = ["left", "right", "top", "bottom"]

function decodeEvent(line) {
  var text = String(line || "").trim()
  if (text === "") return null
  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return { kind: "Malformed", raw: text }
  }
  if (typeof parsed === "string") return { kind: parsed }
  if (parsed === null || typeof parsed !== "object") return null
  for (var key in parsed) return { kind: key, value: parsed[key] }
  return null
}

function encodeRequest(name, value) {
  if (value === undefined) return JSON.stringify(name)
  var payload = {}
  payload[name] = value
  return JSON.stringify(payload)
}

// Peers arrive as [handle, config, state] triples in Created, State, and
// Enumerate alike, so every one of them funnels through here.
function decodePeer(triple) {
  if (!Array.isArray(triple) || triple.length < 3) return null
  var handle = triple[0]
  var config = triple[1] || {}
  var state = triple[2] || {}
  var ips = []
  if (Array.isArray(state.ips)) ips = state.ips.slice()
  else if (state.ips && typeof state.ips === "object") ips = Object.keys(state.ips)

  return {
    handle: handle,
    hostname: config.hostname ? String(config.hostname) : "",
    port: typeof config.port === "number" ? config.port : 4242,
    position: normalizePosition(config.pos),
    fixIps: Array.isArray(config.fix_ips) ? config.fix_ips.slice() : [],
    ips: ips,
    active: state.active === true,
    alive: state.alive === true,
    resolving: state.resolving === true,
    hasPressedKeys: state.has_pressed_keys === true,
    activeAddr: state.active_addr ? String(state.active_addr) : "",
    label: peerLabel(config, state, handle)
  }
}

function peerLabel(config, state, handle) {
  if (config && config.hostname) return String(config.hostname)
  if (state && state.active_addr) return stripPort(String(state.active_addr))
  if (config && Array.isArray(config.fix_ips) && config.fix_ips.length > 0) return String(config.fix_ips[0])
  return "Peer " + handle
}

function stripPort(addr) {
  // IPv6 socket addresses are bracketed, so the last colon is the only
  // reliable separator for either family.
  var cut = addr.lastIndexOf(":")
  if (cut < 0) return addr
  var host = addr.slice(0, cut)
  if (host.charAt(0) === "[" && host.charAt(host.length - 1) === "]") return host.slice(1, -1)
  return host
}

function normalizePosition(pos) {
  var value = String(pos || "left").toLowerCase()
  return POSITIONS.indexOf(value) >= 0 ? value : "left"
}

function oppositePosition(pos) {
  switch (normalizePosition(pos)) {
    case "left": return "right"
    case "right": return "left"
    case "top": return "bottom"
    default: return "top"
  }
}

function upsertPeer(list, peer) {
  if (!peer) return list
  var next = list.slice()
  for (var i = 0; i < next.length; i++) {
    if (next[i].handle === peer.handle) {
      next[i] = peer
      return next
    }
  }
  next.push(peer)
  return next
}

function removePeer(list, handle) {
  var next = []
  for (var i = 0; i < list.length; i++) {
    if (list[i].handle !== handle) next.push(list[i])
  }
  return next
}

function findPeer(list, handle) {
  for (var i = 0; i < list.length; i++) {
    if (list[i].handle === handle) return list[i]
  }
  return null
}

function findPeerByFingerprint(list, fingerprints, fingerprint) {
  // lan-mouse identifies incoming peers by certificate fingerprint but tracks
  // outgoing peers by handle, so entering peers are matched by whichever
  // address the fingerprint last connected from.
  var addr = fingerprints ? fingerprints[fingerprint] : null
  if (!addr) return null
  var host = stripPort(String(addr))
  for (var i = 0; i < list.length; i++) {
    if (list[i].ips.indexOf(host) >= 0) return list[i]
    if (list[i].activeAddr && stripPort(list[i].activeAddr) === host) return list[i]
  }
  return null
}

// A fingerprint is 32 colon-separated hex bytes. Showing all of it in a bar
// panel is unreadable, and showing too little makes confirmation meaningless.
function shortFingerprint(fingerprint) {
  var text = String(fingerprint || "")
  var parts = text.split(":")
  if (parts.length < 8) return text
  return parts.slice(0, 4).join(":") + " ... " + parts.slice(-4).join(":")
}

function isValidFingerprint(fingerprint) {
  return /^[0-9a-f]{2}(:[0-9a-f]{2}){31}$/.test(String(fingerprint || "").toLowerCase())
}

function statusToBool(status) {
  return String(status || "") === "Enabled"
}

// A machine can be driving this screen without our own outgoing link to it
// being up, because the two directions are authorized separately. Reporting
// only the outgoing side made the bar claim "Reaching peer" while the user was
// actively typing from that very machine.
function summarize(peers, incoming) {
  var driving = incoming ? incoming.length : 0
  if (driving === 1) return incoming[0].label + " is driving"
  if (driving > 1) return driving + " machines driving"

  if (peers.length === 0) return "No peers"
  var active = 0
  var alive = 0
  for (var i = 0; i < peers.length; i++) {
    if (peers[i].active) active++
    if (peers[i].active && peers[i].alive) alive++
  }
  if (active === 0) return "Idle"
  if (alive === 0) return "Reaching " + (active === 1 ? "peer" : "peers")
  if (alive === 1) {
    for (var j = 0; j < peers.length; j++) {
      if (peers[j].active && peers[j].alive) return peers[j].label
    }
  }
  return alive + " peers linked"
}

function upsertIncoming(list, entry) {
  if (!entry || !entry.fingerprint) return list
  var next = list.slice()
  for (var i = 0; i < next.length; i++) {
    if (next[i].fingerprint === entry.fingerprint) {
      next[i] = Object.assign({}, next[i], entry)
      return next
    }
  }
  next.push(entry)
  return next
}

function removeIncomingByAddr(list, addr) {
  var host = stripPort(String(addr || ""))
  var next = []
  for (var i = 0; i < list.length; i++) {
    if (stripPort(list[i].addr) !== host) next.push(list[i])
  }
  return next
}

// An incoming connection is identified only by fingerprint and address, so it
// is named after a configured peer when one shares that address.
function incomingLabel(peers, addr) {
  var host = stripPort(String(addr || ""))
  for (var i = 0; i < peers.length; i++) {
    if (peers[i].ips.indexOf(host) >= 0) return peers[i].label
    if (peers[i].activeAddr && stripPort(peers[i].activeAddr) === host) return peers[i].label
  }
  return host === "" ? "Unknown machine" : host
}

function isDrivenBy(incoming, peer) {
  if (!peer) return false
  for (var i = 0; i < incoming.length; i++) {
    var host = stripPort(incoming[i].addr)
    if (peer.ips.indexOf(host) >= 0) return true
    if (peer.activeAddr && stripPort(peer.activeAddr) === host) return true
  }
  return false
}

// A bare address goes in fix_ips; anything else is treated as a name to
// resolve. Getting this wrong means lan-mouse never finds the machine.
function looksLikeAddress(value) {
  var text = String(value || "").trim()
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(text)) return true
  return text.indexOf(":") >= 0 && /^[0-9a-fA-F:]+$/.test(text)
}
