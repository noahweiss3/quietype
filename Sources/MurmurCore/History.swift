import Foundation

public struct HistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var appBundleID: String?
    public var audioSeconds: Double
    public var transcribeSeconds: Double
    public var totalSeconds: Double
    public var result: ProcessedDictation

    public init(id: UUID = UUID(), date: Date = Date(), appBundleID: String?, audioSeconds: Double, transcribeSeconds: Double, totalSeconds: Double, result: ProcessedDictation) {
        self.id = id
        self.date = date
        self.appBundleID = appBundleID
        self.audioSeconds = audioSeconds
        self.transcribeSeconds = transcribeSeconds
        self.totalSeconds = totalSeconds
        self.result = result
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

    public func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? Self.decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    @discardableResult
    public func add(_ entry: HistoryEntry) throws -> [HistoryEntry] {
        let entries = Array(([entry] + load()).prefix(limit))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(entries).write(to: url, options: .atomic)
        return entries
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
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
