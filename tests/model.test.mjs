// Model.js is QML-flavoured JavaScript, so it is loaded into a sandbox with
// the `.pragma` header stripped rather than imported as a module. These cover
// the wire decoding and the peer bookkeeping, which is where a mistake is
// silent rather than loud.
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"
import vm from "node:vm"
import test from "node:test"
import assert from "node:assert/strict"

const here = dirname(fileURLToPath(import.meta.url))
const source = readFileSync(join(here, "..", "Model.js"), "utf8").replace(/^\s*\.pragma\s+library\s*$/m, "")

const exported = [
  "decodeEvent", "encodeRequest", "decodePeer", "stripPort", "normalizePosition",
  "oppositePosition", "upsertPeer", "removePeer", "findPeer", "shortFingerprint",
  "isValidFingerprint", "statusToBool", "summarize", "upsertIncoming",
  "removeIncomingByAddr", "incomingLabel", "isDrivenBy", "looksLikeAddress",
]
// Run in this realm, not a fresh one: objects built inside a separate vm
// context carry a different Object prototype and fail strict deep comparison
// for reasons that have nothing to do with the code under test.
const M = vm.runInThisContext(`${source}\n;({ ${exported.join(", ")} })`)

const peerTriple = [0,
  { hostname: "macbook", fix_ips: ["10.0.4.138"], port: 4242, pos: "right", cmd: null },
  { active: true, active_addr: null, alive: false, dns_ips: [], ips: ["10.0.4.138"],
    has_pressed_keys: false, resolving: false }]

test("decodes serde's externally tagged variants", () => {
  assert.deepEqual(M.decodeEvent('"Create"'), { kind: "Create" })
  assert.deepEqual(M.decodeEvent('{"CaptureStatus":"Enabled"}'), { kind: "CaptureStatus", value: "Enabled" })
  assert.deepEqual(M.decodeEvent('{"Deleted":7}'), { kind: "Deleted", value: 7 })
  assert.equal(M.decodeEvent('{"DeviceEntered":{"pos":"left"}}').value.pos, "left")
  assert.equal(M.decodeEvent(""), null)
})

test("a malformed line is reported, never thrown", () => {
  assert.equal(M.decodeEvent("{not json").kind, "Malformed")
})

test("encodes requests the way lan-mouse expects", () => {
  assert.equal(M.encodeRequest("Create"), '"Create"')
  assert.equal(M.encodeRequest("Activate", [0, true]), '{"Activate":[0,true]}')
  assert.equal(M.encodeRequest("Enumerate", []), '{"Enumerate":[]}')
  assert.equal(M.encodeRequest("UpdatePosition", [1, "right"]), '{"UpdatePosition":[1,"right"]}')
})

test("decodes a peer triple", () => {
  const peer = M.decodePeer(peerTriple)
  assert.equal(peer.handle, 0)
  assert.equal(peer.label, "macbook")
  assert.equal(peer.position, "right")
  assert.equal(peer.active, true)
  assert.equal(peer.alive, false)
  assert.deepEqual(peer.ips, ["10.0.4.138"])
})

test("a short triple is rejected rather than half-decoded", () => {
  assert.equal(M.decodePeer([0]), null)
  assert.equal(M.decodePeer(null), null)
})

test("strips ports without mangling IPv6", () => {
  assert.equal(M.stripPort("10.0.4.138:4242"), "10.0.4.138")
  assert.equal(M.stripPort("[fe80::1]:4242"), "fe80::1")
})

test("positions normalise and invert", () => {
  assert.equal(M.normalizePosition("RIGHT"), "right")
  assert.equal(M.normalizePosition("sideways"), "left")
  assert.equal(M.oppositePosition("top"), "bottom")
})

test("an incoming machine outranks the outgoing link in the summary", () => {
  const peers = [M.decodePeer(peerTriple)]
  // Outgoing is active but not alive, which on its own reads as "Reaching".
  assert.equal(M.summarize(peers, []), "Reaching peer")
  // But if that machine is driving us, saying "Reaching" would be a lie.
  assert.equal(M.summarize(peers, [{ fingerprint: "a", addr: "10.0.4.138:5000", label: "macbook" }]),
    "macbook is driving")
})

test("summarises the empty and idle cases", () => {
  assert.equal(M.summarize([], []), "No peers")
  const idle = M.decodePeer([1, { hostname: "box" }, { active: false, ips: [] }])
  assert.equal(M.summarize([idle], []), "Idle")
})

test("incoming devices dedupe by fingerprint and drop by address", () => {
  let list = M.upsertIncoming([], { fingerprint: "a", addr: "10.0.4.138:1", label: "mac" })
  list = M.upsertIncoming(list, { fingerprint: "a", addr: "10.0.4.138:2", label: "mac" })
  assert.equal(list.length, 1, "same fingerprint must not duplicate")
  assert.equal(list[0].addr, "10.0.4.138:2", "latest address wins")

  list = M.upsertIncoming(list, { fingerprint: "b", addr: "10.0.4.9:3", label: "other" })
  assert.equal(list.length, 2)
  // The disconnect event carries a different source port than the connect did.
  assert.deepEqual(M.removeIncomingByAddr(list, "10.0.4.138:9999").map(e => e.fingerprint), ["b"])
})

test("an incoming connection is named after a matching peer", () => {
  const peers = [M.decodePeer(peerTriple)]
  assert.equal(M.incomingLabel(peers, "10.0.4.138:5000"), "macbook")
  assert.equal(M.incomingLabel(peers, "10.0.9.9:5000"), "10.0.9.9")
  assert.equal(M.incomingLabel(peers, ""), "Unknown machine")
})

test("isDrivenBy matches a peer by address, ignoring port", () => {
  const peer = M.decodePeer(peerTriple)
  assert.equal(M.isDrivenBy([{ addr: "10.0.4.138:6000" }], peer), true)
  assert.equal(M.isDrivenBy([{ addr: "10.0.4.99:6000" }], peer), false)
  assert.equal(M.isDrivenBy([], peer), false)
  assert.equal(M.isDrivenBy([{ addr: "10.0.4.138:1" }], null), false)
})

test("tells an address from a hostname", () => {
  assert.equal(M.looksLikeAddress("10.0.5.1"), true)
  assert.equal(M.looksLikeAddress("fe80::1"), true)
  assert.equal(M.looksLikeAddress("omarchy"), false)
  assert.equal(M.looksLikeAddress("my-box.local"), false)
})

test("fingerprints are validated and shortened", () => {
  const fp = Array(32).fill("ab").join(":")
  assert.equal(M.isValidFingerprint(fp), true)
  assert.equal(M.isValidFingerprint("deadbeef"), false)
  assert.equal(M.isValidFingerprint(""), false)
  assert.ok(M.shortFingerprint(fp).includes("..."))
})

test("status maps to a boolean", () => {
  assert.equal(M.statusToBool("Enabled"), true)
  assert.equal(M.statusToBool("Disabled"), false)
})
