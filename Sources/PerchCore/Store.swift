import Foundation

public struct Store {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Perch", isDirectory: true)
    }

    public let url: URL
    private var backup: URL { url.appendingPathExtension("bak") }

    public init(url: URL) {
        self.url = url
    }

    public enum LoadResult {
        case fresh
        case loaded(AppData)
        /// The main file was unreadable. It was set aside at `corruptCopy`; `data` came from the backup, if any.
        case recovered(AppData, corruptCopy: URL)
    }

    public func load() -> LoadResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            if let data = decode(backup) { return .loaded(data) }
            return .fresh
        }
        if let data = decode(url) { return .loaded(data) }

        // Never let the next save overwrite a file we couldn't read.
        let aside = stamped("corrupt")
        try? fm.moveItem(at: url, to: aside)
        return .recovered(decode(backup) ?? AppData(), corruptCopy: aside)
    }

    /// Writes `data` beside the store in the export format, so it can be restored like any backup. Returns the file.
    public func keepCopy(_ data: AppData) throws -> URL {
        let copy = stamped("before-restore")
        try Store.encoder.encode(data).write(to: copy, options: .withoutOverwriting)
        return copy
    }

    /// `store.<label>-<time>.json`, next to the store.
    private func stamped(_ label: String) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return url.deletingPathExtension().appendingPathExtension("\(label)-\(stamp).json")
    }

    private func decode(_ file: URL) -> AppData? {
        guard let raw = try? Data(contentsOf: file) else { return nil }
        return try? Store.decoder.decode(AppData.self, from: raw)
    }

    public func save(_ data: AppData) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoded = try Store.encoder.encode(data)
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: url, to: backup)
        }
        try encoded.write(to: url, options: .atomic)
    }
}
