import AppKit
import ServiceManagement

/// Crossover lives in the menu bar. There is no main window and no Dock icon:
/// the whole app is a status item, an approval prompt, and a way into the three
/// System Settings panes macOS insists on.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = StatusIcon.image(linked: false)
        statusItem.button?.image?.isTemplate = true

        state.onChange = { [weak self] in self?.refresh() }
        state.start()
        refresh()

        // A Mac with no machine configured cannot do anything useful, so ask
        // once rather than leaving an empty menu.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.state.peers.isEmpty else { return }
            self.addMachine(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.shutdown()
    }

    private func refresh() {
        let driving = !state.incoming.isEmpty
        statusItem.button?.image = StatusIcon.image(linked: driving || state.linked)
        statusItem.button?.image?.isTemplate = true
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: state.summary, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if state.sharingEnabled && !state.captureEnabled {
            let stalled = NSMenuItem(title: "Input is not being captured yet", action: nil, keyEquivalent: "")
            stalled.isEnabled = false
            menu.addItem(stalled)
        }

        if !state.pendingFingerprint.isEmpty {
            menu.addItem(.separator())
            let ask = NSMenuItem(title: "A machine wants to connect", action: nil, keyEquivalent: "")
            ask.isEnabled = false
            menu.addItem(ask)
            let fp = NSMenuItem(title: AppState.shortFingerprint(state.pendingFingerprint), action: nil, keyEquivalent: "")
            fp.isEnabled = false
            menu.addItem(fp)
            menu.addItem(item("Approve this machine…", #selector(approve)))
            menu.addItem(item("Deny", #selector(deny)))
        }

        if !state.peers.isEmpty {
            menu.addItem(.separator())
            let title = NSMenuItem(title: "Machines", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            for peer in state.peers {
                let entry = NSMenuItem(title: peer.label, action: #selector(togglePeer(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = peer.handle
                entry.state = peer.active ? .on : .off
                let suffix = state.isDriving(peer) ? "driving" : peer.position
                entry.title = "\(peer.label)  ·  \(suffix)"
                entry.submenu = peerSubmenu(peer)
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("Add a machine…", #selector(addMachine(_:))))

        let missing = Permission.allCases.filter { Permissions.state(of: $0) == .denied }
        if !missing.isEmpty {
            menu.addItem(.separator())
            let warn = NSMenuItem(title: "Needs permission", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
            for permission in missing {
                let entry = NSMenuItem(title: "\(permission.title) — \(permission.why)",
                                       action: #selector(openPermission(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = permission.rawValue
                menu.addItem(entry)
            }
            // The helper lives inside this bundle, and the Settings "+" picker
            // will not descend into an app package. Revealing it in Finder is
            // the only way to drag it in by hand.
            menu.addItem(item("Show the input helper in Finder", #selector(revealHelper)))
        }

        menu.addItem(.separator())

        let sharing = item(state.sharingEnabled ? "Stop sharing input" : "Start sharing input",
                           #selector(toggleSharing))
        menu.addItem(sharing)

        let clip = item(clipboardTitle(), #selector(toggleClipboard))
        menu.addItem(clip)

        if state.clipboardGaveUp {
            menu.addItem(item("Retry clipboard", #selector(retryClipboard)))
        }

        if !state.fingerprint.isEmpty {
            let mine = NSMenuItem(title: "This Mac: \(AppState.shortFingerprint(state.fingerprint))",
                                  action: #selector(copyFingerprint), keyEquivalent: "")
            mine.target = self
            menu.addItem(mine)
        }

        menu.addItem(.separator())
        let login = item(loginItemEnabled ? "Open at Login ✓" : "Open at Login", #selector(toggleLoginItem))
        menu.addItem(login)
        menu.addItem(item("Quit Crossover", #selector(quit)))
        return menu
    }

    private func clipboardTitle() -> String {
        if state.clipboardGaveUp { return "Clipboard sharing: stopped" }
        return state.clipboardRunning ? "Clipboard sharing ✓" : "Clipboard sharing"
    }

    private func peerSubmenu(_ peer: Peer) -> NSMenu {
        let menu = NSMenu()
        for position in ["left", "right", "top", "bottom"] {
            let entry = NSMenuItem(title: "On my \(position)", action: #selector(setPosition(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = ["handle": peer.handle, "position": position] as [String: Any]
            entry.state = peer.position == position ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove", action: #selector(removePeer(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = peer.handle
        menu.addItem(remove)
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    // MARK: - Actions

    @objc private func togglePeer(_ sender: NSMenuItem) {
        guard let handle = sender.representedObject as? UInt64,
              let peer = state.peers.first(where: { $0.handle == handle }) else { return }
        state.toggle(peer)
    }

    @objc private func setPosition(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let handle = info["handle"] as? UInt64,
              let position = info["position"] as? String,
              let peer = state.peers.first(where: { $0.handle == handle }) else { return }
        state.setPosition(peer, position)
    }

    @objc private func removePeer(_ sender: NSMenuItem) {
        guard let handle = sender.representedObject as? UInt64,
              let peer = state.peers.first(where: { $0.handle == handle }) else { return }
        state.remove(peer)
    }

    @objc private func addMachine(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Add a machine"
        alert.informativeText = "Its hostname or IP address, and which side of this Mac it sits on."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        field.placeholderString = "10.0.5.1 or omarchy.local"
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        picker.addItems(withTitles: ["On my left", "On my right", "Above me", "Below me"])

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 58))
        container.addSubview(field)
        container.addSubview(picker)
        alert.accessoryView = container
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let host = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        let positions = ["left", "right", "top", "bottom"]
        state.addMachine(host: host, position: positions[picker.indexOfSelectedItem])
    }

    @objc private func approve() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Trust this machine?"
        alert.informativeText = """
        It will be able to control this Mac's pointer and keyboard.

        \(state.pendingFingerprint)

        Approve only if that matches the fingerprint shown on the other machine.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Approve")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { state.approvePending() }
    }

    @objc private func deny() { state.denyPending() }

    @objc private func revealHelper() {
        guard let app = BundledHelper.inputAppURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([app])
    }

    @objc private func openPermission(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let permission = Permission(rawValue: raw) else { return }
        switch permission {
        case .accessibility: Permissions.requestAccessibility()
        case .inputMonitoring: Permissions.requestInputMonitoring()
        case .localNetwork: break
        }
        permission.open()
    }

    @objc private func toggleSharing() {
        state.sharingEnabled ? state.stopInput() : state.startInput()
    }

    @objc private func toggleClipboard() {
        state.clipboardRunning ? state.stopClipboard() : state.startClipboard()
    }

    @objc private func retryClipboard() { state.retryClipboard() }

    @objc private func copyFingerprint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.fingerprint, forType: .string)
    }

    private var loginItemEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLoginItem() {
        do {
            if loginItemEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("login item: \(error.localizedDescription)")
        }
        refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// Two screens with the crossing point between them, drawn as a template image
/// so it follows the menu bar's appearance.
enum StatusIcon {
    static func image(linked: Bool) -> NSImage {
        let size = NSSize(width: 20, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let stroke = NSColor.black
            stroke.setStroke()
            stroke.setFill()

            let left = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 2.5, width: 7, height: 9), xRadius: 1.5, yRadius: 1.5)
            left.fill()

            let right = NSBezierPath(roundedRect: NSRect(x: 12.5, y: 2.5, width: 7, height: 9), xRadius: 1.5, yRadius: 1.5)
            right.lineWidth = 1
            right.stroke()

            if linked {
                NSBezierPath(ovalIn: NSRect(x: 9, y: 6, width: 2.5, height: 2.5)).fill()
            }
            _ = rect
            return true
        }
        image.isTemplate = true
        return image
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
