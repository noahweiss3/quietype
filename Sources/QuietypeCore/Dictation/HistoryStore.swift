import Foundation

public struct HistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var appBundleID: String?
    public var audioSeconds: Double
    public var transcribeSeconds: Double
    public var totalSeconds: Double
    public var result: ProcessedDictation

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        appBundleID: String?,
        audioSeconds: Double,
        transcribeSeconds: Double,
        totalSeconds: Double,
        result: ProcessedDictation
    ) {
        self.id = id
        self.date = date
        self.appBundleID = appBundleID
        self.audioSeconds = audioSeconds
        self.transcribeSeconds = transcribeSeconds
        self.totalSeconds = totalSeconds
        self.result = result
    }
}

/// Why the history file couldn't be used.
public enum HistoryError: Error, LocalizedError {
    /// The history file exists but couldn't be read or decoded. `movedTo` is where it was kept
    /// instead, or nil if it couldn't be moved and is still in place.
    case unreadable(movedTo: URL?, underlying: any Error)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(movedTo?, underlying):
            return """
                The saved history couldn't be read. It was kept as \(movedTo.path) and a new history will be \
                started. (\(underlying.localizedDescription))
                """
        case let .unreadable(nil, underlying):
            return """
                The saved history couldn't be read or moved aside, so new dictations can't be saved to it. \
                (\(underlying.localizedDescription))
                """
        }
    }
}

/// The most recent dictations, newest first, kept in a JSON file.
public struct HistoryStore: Sendable {
    public let url: URL
    public var limit: Int

    public init(url: URL, limit: Int = 100) {
        self.url = url
        self.limit = limit
    }

    /// A missing file is an empty history. A file that exists but can't be read or decoded is moved
    /// aside, so the next save can't overwrite it, and `HistoryError.unreadable` is thrown.
    public func load() throws -> [HistoryEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            return try Self.decoder.decode([HistoryEntry].self, from: Data(contentsOf: url))
        } catch {
            throw HistoryError.unreadable(movedTo: try? moveAside(), underlying: error)
        }
    }

    @discardableResult
    public func add(_ entry: HistoryEntry) throws -> [HistoryEntry] {
        let existing: [HistoryEntry]
        do {
            existing = try load()
        } catch HistoryError.unreadable(movedTo: _?, underlying: _) {
            existing = [] // the unreadable file was kept, so starting over loses nothing
        }
        let entries = Array(([entry] + existing).prefix(limit))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(entries).write(to: url, options: .atomic)
        return entries
    }

    /// Removes the history and the unreadable copies `load` kept beside it.
    public func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        for copy in try keptCopies() { try FileManager.default.removeItem(at: copy) }
    }

    /// The start of every name `moveAside` gives an unreadable history.
    private var keptCopyPrefix: String { "\(url.deletingPathExtension().lastPathComponent).unreadable-" }

    private func keptCopies() throws -> [URL] {
        let folder = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(keptCopyPrefix) && $0.pathExtension == url.pathExtension }
    }

    /// Renames the history file to `<name>.unreadable-<yyyyMMdd-HHmmss>.<ext>` next to it and returns
    /// the new location.
    private func moveAside() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = keptCopyPrefix + formatter.string(from: Date())
        let folder = url.deletingLastPathComponent()
        var destination = folder.appendingPathComponent(base).appendingPathExtension(url.pathExtension)
        var number = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(base)-\(number)").appendingPathExtension(url.pathExtension)
            number += 1
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
