import Foundation

/// Client for lan-mouse's control socket.
///
/// On macOS the daemon listens on ~/Library/Caches/lan-mouse-socket.sock. The
/// daemon may not be up yet, or may be restarted underneath us, so connecting
/// is a retry loop rather than a one-shot: link state is derived from traffic
/// arriving, not from any single connect succeeding.
final class LanMouseIPC {
    static var socketPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Caches/lan-mouse-socket.sock")
    }

    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "crossover.ipc")
    private var running = false
    private var onEvent: ((LanMouseEvent) -> Void)?
    private var onConnected: ((Bool) -> Void)?

    func start(onEvent: @escaping (LanMouseEvent) -> Void, onConnected: @escaping (Bool) -> Void) {
        self.onEvent = onEvent
        self.onConnected = onConnected
        guard !running else { return }
        running = true
        queue.async { [weak self] in self?.loop() }
    }

    func stop() {
        running = false
        closeSocket()
    }

    private func loop() {
        while running {
            if connectOnce() {
                notifyConnected(true)
                readLines()
                notifyConnected(false)
            }
            closeSocket()
            if running { Thread.sleep(forTimeInterval: 1.0) }
        }
    }

    private func connectOnce() -> Bool {
        let path = Self.socketPath
        guard FileManager.default.fileExists(atPath: path) else { return false }

        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        // sun_path is a fixed C array; refuse rather than truncate into a path
        // that would silently point somewhere else.
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(sock)
            return false
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(sock, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            close(sock)
            return false
        }
        fd = sock
        return true
    }

    private func readLines() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while running, fd >= 0 {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                if let event = LanMouseEvent.decode(line) {
                    let handler = onEvent
                    DispatchQueue.main.async { handler?(event) }
                }
            }
            // A peer that never sends a newline must not grow this forever.
            if buffer.count > 1 << 20 { buffer.removeAll(keepingCapacity: false) }
        }
    }

    @discardableResult
    func send(_ request: LanMouseRequest) -> Bool {
        queue.async { [weak self] in
            guard let self, self.fd >= 0 else { return }
            let payload = Array((request.json + "\n").utf8)
            var offset = 0
            while offset < payload.count {
                let written = payload.withUnsafeBytes { raw -> Int in
                    write(self.fd, raw.baseAddress!.advanced(by: offset), payload.count - offset)
                }
                if written <= 0 { return }
                offset += written
            }
        }
        return true
    }

    private func notifyConnected(_ value: Bool) {
        let handler = onConnected
        DispatchQueue.main.async { handler?(value) }
    }

    private func closeSocket() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }
}
