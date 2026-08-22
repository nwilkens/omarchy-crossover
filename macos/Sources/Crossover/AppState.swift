import AppKit
import Foundation

/// Everything the menu renders. The daemons are the source of truth; this is a
/// view over them, so nothing here is persisted except the user's own settings.
final class AppState {
    private(set) var peers: [Peer] = []
    /// Machines currently driving this Mac. Tracked separately from peers
    /// because the two directions are authorised independently: the other
    /// machine can be driving us while our own link back to it is refused.
    private(set) var incoming: [String: String] = [:]
    private(set) var fingerprint = ""
    private(set) var pendingFingerprint = ""
    private(set) var dismissedFingerprints: Set<String> = []
    private(set) var captureEnabled = false
    private(set) var emulationEnabled = false
    private(set) var linked = false
    private(set) var lastError = ""

    var onChange: (() -> Void)?

    private let ipc = LanMouseIPC()
    private var clipboard: SupervisedProcess?

    var sharingEnabled: Bool { InputHelper.isRunning }
    var clipboardRunning: Bool { clipboard?.isRunning ?? false }
    var clipboardGaveUp: Bool { clipboard?.gaveUp ?? false }

    var summary: String {
        if !incoming.isEmpty {
            if incoming.count == 1, let addr = incoming.values.first {
                return "\(label(forAddress: addr)) is driving"
            }
            return "\(incoming.count) machines driving"
        }
        guard !peers.isEmpty else { return "No machines yet" }
        let live = peers.filter { $0.active && $0.alive }
        if live.count == 1 { return "Linked to \(live[0].label)" }
        if live.count > 1 { return "\(live.count) machines linked" }
        return peers.contains { $0.active } ? "Reaching…" : "Idle"
    }

    func start() {
        ipc.start(onEvent: { [weak self] event in
            self?.apply(event)
        }, onConnected: { [weak self] connected in
            guard let self else { return }
            self.linked = connected
            if connected { self.ipc.send(.enumerate); self.ipc.send(.sync) } else { self.reset() }
            self.onChange?()
        })
        startInput()
        startClipboard()
    }

    private func reset() {
        peers = []
        incoming = [:]
        captureEnabled = false
        emulationEnabled = false
    }

    private func apply(_ event: LanMouseEvent) {
        switch event {
        case .peers(let list):
            peers = list
        case .peerChanged(let peer):
            if let index = peers.firstIndex(where: { $0.handle == peer.handle }) {
                peers[index] = peer
            } else {
                peers.append(peer)
            }
        case .peerRemoved(let handle):
            peers.removeAll { $0.handle == handle }
        case .captureStatus(let on):
            captureEnabled = on
        case .emulationStatus(let on):
            emulationEnabled = on
        case .fingerprint(let value):
            fingerprint = value
        case .connectionAttempt(let fp):
            // A machine we already refused must not be able to re-raise the
            // prompt until the user asks for it again.
            if !dismissedFingerprints.contains(fp) { pendingFingerprint = fp }
        case .deviceConnected(let fp, let addr), .deviceEntered(let fp, let addr, _):
            incoming[fp] = addr
        case .incomingDisconnected(let addr):
            let host = AppState.stripPort(addr)
            incoming = incoming.filter { AppState.stripPort($0.value) != host }
        case .error(let message):
            lastError = message
        case .authorizedUpdated, .unknown:
            break
        }
        onChange?()
    }

    // MARK: - Actions

    func addMachine(host: String, position: String) {
        pendingHost = (host, position)
        ipc.send(.create)
        // The handle only arrives with Created, so the name is applied there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.applyPendingHost()
        }
    }

    private var pendingHost: (host: String, position: String)?

    private func applyPendingHost() {
        guard let pending = pendingHost, let peer = peers.last else { return }
        pendingHost = nil
        if AppState.looksLikeAddress(pending.host) {
            ipc.send(.updateFixIps(peer.handle, [pending.host]))
        } else {
            ipc.send(.updateHostname(peer.handle, pending.host))
            ipc.send(.resolveDns(peer.handle))
        }
        ipc.send(.updatePosition(peer.handle, pending.position))
        ipc.send(.activate(peer.handle, true))
        ipc.send(.saveConfiguration)
    }

    func toggle(_ peer: Peer) {
        ipc.send(.activate(peer.handle, !peer.active))
    }

    func setPosition(_ peer: Peer, _ position: String) {
        ipc.send(.updatePosition(peer.handle, position))
        ipc.send(.saveConfiguration)
    }

    func remove(_ peer: Peer) {
        ipc.send(.delete(peer.handle))
        ipc.send(.saveConfiguration)
    }

    func approvePending() {
        guard !pendingFingerprint.isEmpty else { return }
        ipc.send(.authorizeKey("crossover", pendingFingerprint))
        ipc.send(.saveConfiguration)
        pendingFingerprint = ""
        onChange?()
    }

    func denyPending() {
        guard !pendingFingerprint.isEmpty else { return }
        dismissedFingerprints.insert(pendingFingerprint)
        pendingFingerprint = ""
        onChange?()
    }

    func startInput() {
        InputHelper.launch(arguments: ["--emulation-backend", "mac-os", "daemon"])
        onChange?()
    }

    func stopInput() {
        InputHelper.terminate()
        onChange?()
    }

    func startClipboard() {
        guard let binary = BundledHelper.clipboardBinaryURL else { return }
        if clipboard == nil {
            let process = SupervisedProcess(executable: binary, arguments: ["run"])
            process.onStateChange = { [weak self] in self?.onChange?() }
            clipboard = process
        }
        clipboard?.start()
    }

    func stopClipboard() {
        clipboard?.stop()
    }

    func retryClipboard() {
        clipboard?.retry()
    }

    func shutdown() {
        stopClipboard()
        stopInput()
        ipc.stop()
    }

    // MARK: - Helpers

    func label(forAddress addr: String) -> String {
        let host = AppState.stripPort(addr)
        if let match = peers.first(where: { $0.addresses.contains(host) }) { return match.label }
        return host.isEmpty ? "Unknown machine" : host
    }

    func isDriving(_ peer: Peer) -> Bool {
        incoming.values.contains { peer.addresses.contains(AppState.stripPort($0)) }
    }

    static func stripPort(_ addr: String) -> String {
        guard let cut = addr.lastIndex(of: ":") else { return addr }
        var host = String(addr[addr.startIndex..<cut])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host
    }

    static func looksLikeAddress(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) { return true }
        return text.contains(":") && text.allSatisfy { $0.isHexDigit || $0 == ":" }
    }

    static func shortFingerprint(_ value: String) -> String {
        let parts = value.split(separator: ":")
        guard parts.count >= 8 else { return value }
        return parts.prefix(4).joined(separator: ":") + " … " + parts.suffix(4).joined(separator: ":")
    }
}
