import Foundation

/// Where cleanup models live on disk, and downloading them.
public enum ModelStore {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/Models", isDirectory: true)
    }

    public static func path(for model: CleanupModel) -> URL {
        directory.appendingPathComponent(model.fileName)
    }

    public static func isDownloaded(_ model: CleanupModel) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path(for: model).path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return size > model.approximateBytes / 2
    }

    /// Downloads `model` if needed, reporting progress in [0, 1].
    public static func download(_ model: CleanupModel, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let destination = path(for: model)
        if isDownloaded(model) { return destination }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let downloader = Downloader(progress: progress)
        let temporary = try await downloader.download(model.url)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}

/// URLSession download with progress, wrapped for async/await.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = session
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is deleted when this returns, so move it first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
        do {
            if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                throw URLError(.badServerResponse)
            }
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        continuation?.resume(with: result)
        continuation = nil
        session?.finishTasksAndInvalidate()
        session = nil
    }
}
