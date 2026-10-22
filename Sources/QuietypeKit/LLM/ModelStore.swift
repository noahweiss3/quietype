import CryptoKit
import Foundation

/// Where cleanup models live on disk, and downloading them.
public enum ModelStore {
    public enum DownloadError: LocalizedError, CustomStringConvertible {
        case sizeMismatch(expected: Int64, actual: Int64)
        case checksumMismatch(expected: String, actual: String)

        public var description: String {
            switch self {
            case let .sizeMismatch(expected, actual):
                return "the download is \(actual) bytes but should be \(expected); try again"
            case let .checksumMismatch(expected, actual):
                return "the download's SHA-256 is \(actual) but should be \(expected); try again"
            }
        }

        public var errorDescription: String? { description }
    }

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quietype/Models", isDirectory: true)
    }

    public static func path(for model: CleanupModel) -> URL {
        directory.appendingPathComponent(model.fileName)
    }

    /// True when the file is there at exactly the expected size. The SHA-256 is checked once, at
    /// download, before the file is moved into place: hashing 2.5 GB on every launch would take
    /// seconds, and the size still catches a missing or truncated file.
    public static func isDownloaded(_ model: CleanupModel) -> Bool {
        size(of: path(for: model)) == model.bytes
    }

    /// Downloads `model` if needed, reporting progress in [0, 1]. The file only replaces what is
    /// on disk once its size and SHA-256 match, so a broken download never ends up where the app
    /// loads the model from. `replacing` downloads again even when a file of the right size is
    /// there, for a copy that was damaged after it was verified.
    public static func download(
        _ model: CleanupModel, replacing: Bool = false, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let destination = path(for: model)
        if !replacing, isDownloaded(model) { return destination }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Next to the destination, so moving it into place is an atomic rename.
        let partial = directory.appendingPathComponent(model.fileName + ".download")
        defer { try? FileManager.default.removeItem(at: partial) }
        try await Downloader(file: partial, progress: progress).download(model.url)
        try verify(partial, against: model)

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }

    static func verify(_ file: URL, against model: CleanupModel) throws {
        let actualSize = size(of: file) ?? 0
        guard actualSize == model.bytes else {
            throw DownloadError.sizeMismatch(expected: model.bytes, actual: actualSize)
        }
        let digest = try sha256(of: file)
        guard digest == model.sha256 else {
            throw DownloadError.checksumMismatch(expected: model.sha256, actual: digest)
        }
    }

    /// Hex SHA-256 of a file, read in chunks so a multi-gigabyte model never sits in memory.
    static func sha256(of file: URL) throws -> String {
        guard let stream = InputStream(url: file) else { throw CocoaError(.fileReadUnknown) }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? CocoaError(.fileReadUnknown) }
            if count == 0 { break }
            hasher.update(data: buffer[..<count])
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func size(of file: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }
}

/// URLSession download with progress, wrapped for async/await.
///
/// `@unchecked Sendable` is sound because `continuation` and `session` are set before the task
/// starts and from then on only touched in delegate callbacks, which URLSession delivers one at
/// a time on its own serial queue.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let file: URL
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?

    /// Downloads to `file`, replacing anything already there.
    init(file: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.file = file
        self.progress = progress
    }

    func download(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = session
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is deleted when this returns, so move it first.
        do {
            if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                throw URLError(.badServerResponse)
            }
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: location, to: file)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<Void, Error>) {
        continuation?.resume(with: result)
        continuation = nil
        session?.finishTasksAndInvalidate()
        session = nil
    }
}
