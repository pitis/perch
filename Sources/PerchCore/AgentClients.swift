import Foundation

/// The apps that can connect to Perch's MCP server. All three use the same `mcpServers` config shape.
public struct AgentClient: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// Config file, relative to the home folder.
    public var configPath: String
    /// nil for a CLI, which picks up the change on its next run.
    public var bundleId: String?
    public var appPath: String?

    public static let all = [
        AgentClient(id: "claude-code", name: "Claude Code", configPath: ".claude.json", bundleId: nil, appPath: nil),
        AgentClient(id: "claude-app", name: "Claude app", configPath: "Library/Application Support/Claude/claude_desktop_config.json",
                    bundleId: "com.anthropic.claudefordesktop", appPath: "/Applications/Claude.app"),
        AgentClient(id: "cursor", name: "Cursor", configPath: ".cursor/mcp.json",
                    bundleId: "com.todesktop.230313mzl4w4u92", appPath: "/Applications/Cursor.app"),
    ]
}

public enum AgentConfigError: Error, LocalizedError {
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path): "\(path) isn't valid JSON, so Perch left it untouched. Fix the file and try again."
        }
    }
}

public enum AgentConfig {
    public static let serverName = "perch"

    private static func url(_ client: AgentClient, home: URL) -> URL {
        home.appendingPathComponent(client.configPath)
    }

    private static func read(_ file: URL) throws -> [String: Any]? {
        guard let raw = try? Data(contentsOf: file) else { return nil }
        if raw.allSatisfy({ ($0 as UInt8) == 32 || $0 == 10 || $0 == 13 || $0 == 9 }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw AgentConfigError.unreadable(file.path)
        }
        return object
    }

    /// These files hold other settings, and sometimes credentials: keep a backup and keep their permissions.
    private static func write(_ object: [String: Any], to file: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let attributes = try? fm.attributesOfItem(atPath: file.path)
        let permissions = attributes?[.posixPermissions]
        if fm.fileExists(atPath: file.path) {
            let backup = file.appendingPathExtension("perch-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: file, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)
        if let permissions { try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path) }
    }

    public static func isConnected(_ client: AgentClient, home: URL) -> Bool {
        let object = (try? read(url(client, home: home))) ?? nil
        return (object?["mcpServers"] as? [String: Any])?[serverName] != nil
    }

    public static func connect(_ client: AgentClient, executable: String, home: URL) throws {
        let file = url(client, home: home)
        var object = try read(file) ?? [:]
        var servers = object["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = ["command": executable, "args": ["--mcp"]] as [String: Any]
        object["mcpServers"] = servers
        try write(object, to: file)
    }

    public static func disconnect(_ client: AgentClient, home: URL) throws {
        let file = url(client, home: home)
        guard var object = try read(file), var servers = object["mcpServers"] as? [String: Any],
              servers[serverName] != nil else { return }
        servers[serverName] = nil
        object["mcpServers"] = servers
        try write(object, to: file)
    }
}
