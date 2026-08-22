import AppKit
import ApplicationServices
import Foundation
import IOKit.hid

/// The three gates macOS puts in front of moving someone's cursor from another
/// machine. None of them can be granted programmatically; the most an app may
/// do is ask, and then send the user to the right pane.
enum Permission: String, CaseIterable, Identifiable {
    case localNetwork
    case inputMonitoring
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localNetwork: return "Local Network"
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility: return "Accessibility"
        }
    }

    var why: String {
        switch self {
        case .localNetwork: return "Reach the other machine on your network"
        case .inputMonitoring: return "Read the mouse and keyboard to send them"
        case .accessibility: return "Capture input before other apps see it"
        }
    }

    /// Deep links into the exact pane. Accessibility is requested last on
    /// purpose: granting it restarts the helper, so anything asked afterwards
    /// would be interrupted.
    var settingsURL: URL? {
        switch self {
        case .localNetwork:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
        case .inputMonitoring:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }

    func open() {
        guard let url = settingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}

enum PermissionState {
    case granted
    case denied
    /// Local Network has no query API. Claiming to know its state would be a
    /// lie, so it is reported as unknown and explained instead.
    case unknown
}

enum Permissions {
    static func state(of permission: Permission) -> PermissionState {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .inputMonitoring:
            let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
            switch access {
            case kIOHIDAccessTypeGranted: return .granted
            default: return .denied
            }
        case .localNetwork:
            return .unknown
        }
    }

    /// Shows the system prompt rather than only deep-linking, so a first run
    /// looks like every other Mac app.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}
