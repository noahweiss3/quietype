import FluidAudio
import Foundation
import QuietypeCore

/// Parakeet speech recognition on the Neural Engine, via FluidAudio.
public actor ParakeetTranscriber: SpeechTranscriber {
    public enum Variant: String, CaseIterable, Codable, Sendable {
        /// Best accuracy, 25 languages (FluidAudio's recommended default).
        case ultra
        /// English only, slightly better on rare English words.
        case v2
        /// English only, fastest encoder. Needs macOS 15.
        case phonon2

        public var displayName: String {
            switch self {
            case .ultra: return "Parakeet Ultra (most accurate)"
            case .v2: return "Parakeet v2 (English)"
            case .phonon2: return "Phonon-2 (English, fastest, macOS 15+)"
            }
        }

        var version: AsrModelVersion {
            switch self {
            case .ultra: return .ultra
            case .v2: return .v2
            case .phonon2: return .phonon2
            }
        }
    }

    public private(set) var variant: Variant?
    private var manager: AsrManager?
    /// The variant asked for most recently. Loads overlap when the user switches models, and one
    /// that finishes after a newer request must not replace it.
    private var requested: Variant?
    /// In-flight loads, so asking for the same variant again waits on the same work.
    private var loads: [Variant: Task<AsrManager, Error>] = [:]

    public init() {}

    public var isLoaded: Bool { manager != nil }

    /// Downloads (first run only) and compiles the CoreML models. Throws `CancellationError` if
    /// another variant was requested before this one finished; the newer request wins.
    public func load(_ variant: Variant, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        requested = variant
        if self.variant == variant, manager != nil { return }
        let task = loads[variant] ?? Task { try await Self.makeManager(variant, progress: progress) }
        loads[variant] = task
        let loaded: AsrManager
        do {
            loaded = try await task.value
        } catch {
            if loads[variant] == task { loads[variant] = nil }
            throw error
        }
        if loads[variant] == task { loads[variant] = nil }
        guard requested == variant else { throw CancellationError() }
        guard self.variant != variant || manager == nil else { return } // a duplicate request installed it
        manager = loaded
        self.variant = variant

        // The first inference compiles and warms up the Neural Engine path; do it now, not on
        // the user's first dictation.
        _ = try? await transcribe([Float](repeating: 0, count: 16_000))
    }

    private static func makeManager(
        _ variant: Variant, progress: (@Sendable (Double) -> Void)?
    ) async throws -> AsrManager {
        let directory: URL
        do {
            directory = try await AsrModels.download(version: variant.version) { update in
                progress?(update.fractionCompleted)
            }
        } catch {
            throw TranscriberError.downloadFailed(error)
        }
        do {
            let models = try await AsrModels.load(from: directory, version: variant.version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        } catch {
            throw TranscriberError.loadFailed(error)
        }
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw TranscriberError.notLoaded }
        var audio = samples
        // Parakeet needs at least a second of audio; pad short clips with silence.
        if audio.count < 16_000 { audio += [Float](repeating: 0, count: 16_000 - audio.count) }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audio, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Converts any audio file to 16 kHz mono samples.
    public static func loadAudioFile(_ url: URL) throws -> [Float] {
        try AudioConverter().resampleAudioFile(url)
    }
}

public enum TranscriberError: LocalizedError {
    case notLoaded
    case downloadFailed(Error)
    case loadFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .notLoaded: return "The speech model isn't loaded yet."
        case let .downloadFailed(error): return "Couldn't download the speech model: \(error.localizedDescription)"
        case let .loadFailed(error): return "Couldn't load the speech model: \(error.localizedDescription)"
        }
    }
}
