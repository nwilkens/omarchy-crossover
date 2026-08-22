import Foundation

/// lan-mouse speaks newline-delimited JSON in serde's externally tagged enum
/// form: unit variants as bare strings, single-field variants as
/// {"Name": value}, tuple variants as {"Name": [a, b]}, struct variants as
/// {"Name": {...}}. This is the same shape the Linux plugin decodes, and the
/// same defensive rules apply: a line that will not parse must never take the
/// connection down.
enum LanMouseEvent {
    case peers([Peer])
    case peerChanged(Peer)
    case peerRemoved(UInt64)
    case captureStatus(Bool)
    case emulationStatus(Bool)
    case fingerprint(String)
    case authorizedUpdated([String: String])
    case connectionAttempt(String)
    case deviceConnected(fingerprint: String, addr: String)
    case deviceEntered(fingerprint: String, addr: String, position: String)
    case incomingDisconnected(String)
    case error(String)
    case unknown(String)

    static func decode(_ line: String) -> LanMouseEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard let any = try? JSONSerialization.jsonObject(with: data) else {
            return .unknown(trimmed)
        }
        if let name = any as? String { return .unknown(name) }
        guard let object = any as? [String: Any], let key = object.keys.first else { return nil }
        let value = object[key]

        switch key {
        case "Enumerate":
            let raw = value as? [[Any]] ?? []
            return .peers(raw.compactMap(Peer.init(triple:)))
        case "Created", "State":
            guard let triple = value as? [Any], let peer = Peer(triple: triple) else { return nil }
            return .peerChanged(peer)
        case "Deleted":
            guard let handle = value as? UInt64 else { return nil }
            return .peerRemoved(handle)
        case "CaptureStatus":
            return .captureStatus((value as? String) == "Enabled")
        case "EmulationStatus":
            return .emulationStatus((value as? String) == "Enabled")
        case "PublicKeyFingerprint":
            return .fingerprint((value as? String) ?? "")
        case "AuthorizedUpdated":
            return .authorizedUpdated((value as? [String: String]) ?? [:])
        case "ConnectionAttempt":
            guard let d = value as? [String: Any], let fp = d["fingerprint"] as? String else { return nil }
            return .connectionAttempt(fp)
        case "DeviceConnected":
            guard let d = value as? [String: Any],
                  let fp = d["fingerprint"] as? String, let addr = d["addr"] as? String else { return nil }
            return .deviceConnected(fingerprint: fp, addr: addr)
        case "DeviceEntered":
            guard let d = value as? [String: Any],
                  let fp = d["fingerprint"] as? String, let addr = d["addr"] as? String else { return nil }
            return .deviceEntered(fingerprint: fp, addr: addr, position: (d["pos"] as? String) ?? "left")
        case "IncomingDisconnected":
            return .incomingDisconnected((value as? String) ?? "")
        case "Error":
            return .error((value as? String) ?? "")
        default:
            return .unknown(key)
        }
    }
}

struct Peer: Identifiable, Equatable {
    let handle: UInt64
    var hostname: String
    var port: UInt16
    var position: String
    var addresses: [String]
    var active: Bool
    var alive: Bool

    var id: UInt64 { handle }

    var label: String {
        if !hostname.isEmpty { return hostname }
        if let first = addresses.first { return first }
        return "Machine \(handle)"
    }

    init?(triple: [Any]) {
        guard triple.count >= 3,
              let handle = triple[0] as? UInt64,
              let config = triple[1] as? [String: Any],
              let state = triple[2] as? [String: Any] else { return nil }
        self.handle = handle
        self.hostname = config["hostname"] as? String ?? ""
        self.port = (config["port"] as? UInt16) ?? 4242
        self.position = Peer.normalize(config["pos"] as? String)
        self.active = state["active"] as? Bool ?? false
        self.alive = state["alive"] as? Bool ?? false
        // `ips` arrives as an array; fall back to the configured fixed list.
        if let ips = state["ips"] as? [String] {
            self.addresses = ips
        } else {
            self.addresses = config["fix_ips"] as? [String] ?? []
        }
    }

    static func normalize(_ value: String?) -> String {
        let candidates = ["left", "right", "top", "bottom"]
        let lowered = (value ?? "left").lowercased()
        return candidates.contains(lowered) ? lowered : "left"
    }
}

/// Requests use the same externally tagged encoding.
enum LanMouseRequest {
    case enumerate
    case sync
    case create
    case activate(UInt64, Bool)
    case delete(UInt64)
    case updateHostname(UInt64, String?)
    case updateFixIps(UInt64, [String])
    case updatePosition(UInt64, String)
    case resolveDns(UInt64)
    case authorizeKey(String, String)
    case removeAuthorizedKey(String)
    case saveConfiguration

    var json: String {
        func encode(_ name: String, _ payload: Any) -> String {
            let data = try? JSONSerialization.data(withJSONObject: [name: payload])
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(name)\""
        }
        switch self {
        case .enumerate: return encode("Enumerate", [])
        case .sync: return "\"Sync\""
        case .create: return "\"Create\""
        case .saveConfiguration: return "\"SaveConfiguration\""
        case .activate(let h, let on): return encode("Activate", [h, on])
        case .delete(let h): return encode("Delete", h)
        case .updateHostname(let h, let name): return encode("UpdateHostname", [h, name as Any])
        case .updateFixIps(let h, let ips): return encode("UpdateFixIps", [h, ips])
        case .updatePosition(let h, let pos): return encode("UpdatePosition", [h, pos])
        case .resolveDns(let h): return encode("ResolveDns", h)
        case .authorizeKey(let desc, let fp): return encode("AuthorizeKey", [desc, fp])
        case .removeAuthorizedKey(let fp): return encode("RemoveAuthorizedKey", fp)
        }
    }
}
