import FluidAudio
import Foundation
import MurmurCore

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

    public init() {}

    public var isLoaded: Bool { manager != nil }

    /// Downloads (first run only) and compiles the CoreML models.
    public func load(_ variant: Variant, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if self.variant == variant, manager != nil { return }
        let models = try await AsrModels.downloadAndLoad(version: variant.version) { update in
            progress?(update.fractionCompleted)
        }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        self.variant = variant

        // The first inference compiles and warms up the Neural Engine path; do it now, not on
        // the user's first dictation.
        _ = try? await transcribe([Float](repeating: 0, count: 16_000))
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

public enum TranscriberError: Error {
    case notLoaded
}
