import AppKit
import Foundation

/// Locations of the things we ship inside the bundle. Everything Crossover
/// runs lives in its own bundle, so there is one artifact on disk and dragging
/// it to the Trash is a complete uninstall.
enum BundledHelper {
    /// The nested helper app whose executable is lan-mouse. It is a real app
    /// bundle rather than a bare binary so macOS has something to name in the
    /// permissions list, and so TCC attributes the event tap to it.
    static var inputAppURL: URL? {
        Bundle.main.url(forResource: nil, withExtension: nil, subdirectory: "Helpers")
            .map { $0.appendingPathComponent("Crossover Input.app") }
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Crossover Input.app")
    }

    static var inputBinaryURL: URL? {
        inputAppURL?.appendingPathComponent("Contents/MacOS/lan-mouse")
    }

    static var clipboardBinaryURL: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "crossover-clipd")
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/crossover-clipd")
    }
}

/// Supervises one child process: restarts it if it dies, gives up after
/// repeated rapid failures rather than respawning forever, and surfaces the
/// last thing it said on the way out.
final class SupervisedProcess {
    private(set) var isRunning = false
    private(set) var lastError: String = ""
    private(set) var gaveUp = false

    private let executable: URL
    private let arguments: [String]
    private var process: Process?
    private var failures = 0
    private var wanted = false
    private var errorPipe: Pipe?

    var onStateChange: (() -> Void)?

    init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    func start() {
        wanted = true
        guard !isRunning, !gaveUp else { return }
        spawn()
    }

    func stop() {
        wanted = false
        failures = 0
        gaveUp = false
        process?.terminate()
        process = nil
        isRunning = false
        onStateChange?()
    }

    func retry() {
        failures = 0
        gaveUp = false
        start()
    }

    private func spawn() {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            lastError = "missing: \(executable.lastPathComponent)"
            gaveUp = true
            onStateChange?()
            return
        }

        let task = Process()
        task.executableURL = executable
        task.arguments = arguments

        let pipe = Pipe()
        task.standardError = pipe
        errorPipe = pipe

        task.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunning = false
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                if let text = String(data: data, encoding: .utf8) {
                    let lines = text.split(separator: "\n").filter { !$0.isEmpty }
                    if let last = lines.last { self.lastError = String(last) }
                }
                guard self.wanted, finished.terminationStatus != 0 else {
                    self.onStateChange?()
                    return
                }
                self.failures += 1
                if self.failures >= 3 {
                    self.gaveUp = true
                    self.onStateChange?()
                } else {
                    self.onStateChange?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self, self.wanted, !self.gaveUp else { return }
                        self.spawn()
                    }
                }
            }
        }

        do {
            try task.run()
            process = task
            isRunning = true
            onStateChange?()
        } catch {
            lastError = error.localizedDescription
            failures += 1
            if failures >= 3 { gaveUp = true }
            onStateChange?()
        }
    }
}

/// The input helper is launched through LaunchServices rather than spawned, so
/// macOS treats it as its own responsible application. Spawning it as a child
/// would make Crossover responsible for its TCC prompts, and the permission
/// would then be attributed to the wrong bundle.
enum InputHelper {
    static func launch(arguments: [String]) {
        guard let app = BundledHelper.inputAppURL,
              FileManager.default.fileExists(atPath: app.path) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, _ in }
    }

    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.nwilkens.crossover.input"
        }
    }

    static func terminate() {
        for app in NSWorkspace.shared.runningApplications
        where app.bundleIdentifier == "com.nwilkens.crossover.input" {
            app.terminate()
        }
    }
}
