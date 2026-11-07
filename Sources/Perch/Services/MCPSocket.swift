import Foundation
import PerchCore

enum MCPSocket {
    static var path: String { Store.supportDirectory.appendingPathComponent("mcp.sock").path }

    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 {
                    if n < 0, errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
    }
}

/// The app's end of the MCP connection. A Unix socket with owner-only permissions, so only this user's
/// processes can reach it and nothing is ever exposed to the network.
final class MCPSocketServer {
    private let path: String
    private let handler: (String) -> String?
    private var listener: Int32 = -1

    init(path: String, handler: @escaping (String) -> String?) {
        self.path = path
        self.handler = handler
    }

    func start() {
        signal(SIGPIPE, SIG_IGN)
        unlink(path)
        guard var address = MCPSocket.address(path) else {
            NSLog("Perch: MCP is off because the socket path is too long: %@", path)
            return
        }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            NSLog("Perch: MCP is off, couldn't create a socket (errno %d)", errno)
            return
        }

        // The umask closes the gap between bind creating the file and chmod tightening it.
        let previous = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previous)
        guard bound == 0, listen(listener, 8) == 0 else {
            NSLog("Perch: MCP is off, couldn't listen on %@ (errno %d)", path, errno)
            close(listener)
            return
        }
        chmod(path, 0o600)

        Thread.detachNewThread { [self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return
                }
                Thread.detachNewThread { [self] in serve(client) }
            }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return }
            pending.append(contentsOf: buffer[0..<n])
            while let newline = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                // Everything that touches the Workspace runs on the main thread.
                let reply = DispatchQueue.main.sync { handler(line) }
                if let reply, !MCPSocket.writeAll(fd, Data((reply + "\n").utf8)) { return }
            }
        }
    }
}

/// `Perch --mcp`, started by Claude Code, the Claude app or Cursor. It connects stdin and stdout to the running
/// app, starting it if needed, because the timers and the single writer to the data live there.
enum MCPProxy {
    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        guard let fd = connectToApp() else {
            FileHandle.standardError.write(Data("Perch isn't running and couldn't be started.\n".utf8))
            exit(1)
        }

        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(STDIN_FILENO, &buffer, buffer.count)
                if n < 0, errno == EINTR { continue }
                if n <= 0 {
                    // Input is finished, but replies may still be on their way back.
                    shutdown(fd, SHUT_WR)
                    return
                }
                if !MCPSocket.writeAll(fd, Data(buffer[0..<n])) { exit(1) }
            }
        }

        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { exit(0) }
            if !MCPSocket.writeAll(STDOUT_FILENO, Data(buffer[0..<n])) { exit(1) }
        }
    }

    private static func connectToApp() -> Int32? {
        if let fd = attempt() { return fd }

        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = ["-g", Bundle.main.bundlePath]
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        try? launcher.run()

        for _ in 0..<40 {
            usleep(250_000)
            if let fd = attempt() { return fd }
        }
        return nil
    }

    private static func attempt() -> Int32? {
        guard var address = MCPSocket.address(MCPSocket.path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result == 0 { return fd }
        close(fd)
        return nil
    }
}
