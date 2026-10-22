import Foundation
import QuietypeCore
import llama
import os

/// The on-device cleanup LLM.
///
/// At load time the fixed part of the prompt (system prompt and examples) is evaluated once and
/// stays in the KV cache. Each dictation then only evaluates its own short suffix and generates
/// with prompt-lookup speculative decoding.
///
/// `@unchecked Sendable` is sound because once `init` returns the llama context is only touched
/// on `queue`, a serial queue, and the two mutable values shared with callers (`speculative`,
/// `lastStats`) sit behind `state`'s lock. Everything else is immutable.
public final class LlamaCleaner: TextCleaner, @unchecked Sendable {
    public struct Stats: Sendable {
        public var promptTokens = 0
        public var outputTokens = 0
        public var decode = DecodeStats()
        public var prefillSeconds = 0.0
        public var generateSeconds = 0.0
        /// Whether the answer ended on its own or was cut off at the token limit.
        public var stop: GenerationStop { decode.stop }
    }

    public let model: CleanupModel
    private let session: LlamaSession
    private let queue = DispatchQueue(label: "quietype.llama", qos: .userInitiated)
    private let prefixLength: Int
    private let suffixTemplate: String

    private struct State {
        var speculative = true
        var lastStats = Stats()
    }

    /// The app flips `speculative` from the main thread while a cleanup may be running, and
    /// `lastStats` is written on `queue` but read by callers.
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Turn off to compare against plain greedy decoding.
    public var speculative: Bool {
        get { state.withLock { $0.speculative } }
        set { state.withLock { $0.speculative = newValue } }
    }

    public var lastStats: Stats { state.withLock { $0.lastStats } }

    /// Time to evaluate 8 tokens at once divided by the time for 1, measured at load.
    /// Speculation only pays off when a small batch costs about the same as a single token. That
    /// depends on the GPU (on an M2 Air it doesn't), so it is measured rather than assumed.
    public let batchCostRatio: Double
    public var speculationPaysOff: Bool { batchCostRatio < 2.0 }

    private init(model: CleanupModel, session: LlamaSession) throws {
        self.model = model
        self.session = session

        let rendered = try session.applyTemplate(
            CleanupPrompt.prefixMessages + [ChatMessage(role: "user", content: CleanupPrompt.contentMarker)],
            addAssistant: true
        )
        guard let marker = rendered.range(of: CleanupPrompt.contentMarker) else { throw LlamaError.templateFailed }
        suffixTemplate = String(rendered[marker.upperBound...]) + model.assistantPrefill

        let prefix = try session.tokenize(String(rendered[..<marker.lowerBound]), addSpecial: true)
        try session.decode(prefix, at: 0, allLogits: false)
        prefixLength = prefix.count
        batchCostRatio = Self.measureBatchCost(session, at: prefix.count, using: prefix)
    }

    private static func measureBatchCost(
        _ session: LlamaSession, at position: Int, using tokens: [llama_token]
    ) -> Double {
        func fastest(_ count: Int) -> Double {
            var best = Double.infinity
            for _ in 0..<3 {
                let started = Date()
                guard (try? session.decode(Array(tokens.suffix(count)), at: position, allLogits: true)) != nil else {
                    return .infinity
                }
                best = min(best, Date().timeIntervalSince(started))
                try? session.removeTokens(from: position)
            }
            return best
        }
        _ = fastest(1) // warm-up
        let single = fastest(1)
        let batch = fastest(8)
        return single > 0 && single.isFinite && batch.isFinite ? batch / single : .infinity
    }

    /// Loads the model and caches the prompt prefix. Takes a few seconds; call it off the main thread.
    public static func load(_ model: CleanupModel, path: URL, gpuLayers: Int32? = nil) async throws -> LlamaCleaner {
        let layers = gpuLayers ?? ProcessInfo.processInfo.environment["QUIETYPE_GPU_LAYERS"].flatMap(Int32.init) ?? 999
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        try LlamaCleaner(model: model, session: LlamaSession(modelPath: path.path, gpuLayers: layers))
                    })
            }
        }
    }

    /// A generator for longer jobs (meeting notes) on the same model. It has its own context, so
    /// the cleanup prompt stays cached, and runs on this cleaner's queue, so the two never compute
    /// at once and a dictation waits at most for one notes request.
    public func makeGenerator(contextLength: Int = MeetingNotesPrompt.contextTokens) async throws -> LlamaGenerator {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(
                    with: Result {
                        let shared = try LlamaSession(sharingModelOf: self.session, contextLength: contextLength)
                        return LlamaGenerator(
                            session: shared,
                            queue: self.queue,
                            assistantPrefill: self.model.assistantPrefill,
                            speculative: self.speculative && self.speculationPaysOff
                        )
                    })
            }
        }
    }

    public func clean(_ dictation: String, style: WritingStyle, vocabulary: [String]) async throws -> String {
        let content = CleanupPrompt.userContent(dictation: dictation, style: style, vocabulary: vocabulary)
        let result = try await complete(userContent: content)
        // A cut-off answer can still pass the output guard as a long enough prefix, so it fails
        // here instead and the dictation falls back to the rules pass, as meeting notes do.
        guard result.stats.stop == .endOfGeneration else { throw LlamaError.outputTruncated(result.stats.outputTokens) }
        return result.text
    }

    /// Runs one cleanup from a fully built user message. Exposed for tests and benchmarks. Unlike
    /// `clean`, it returns a cut-off answer too; `stats.stop` says whether it was.
    /// `speculative` forces speculation on or off; by default it follows the setting and the
    /// load-time measurement.
    public func complete(userContent: String, speculative: Bool? = nil) async throws -> (text: String, stats: Stats) {
        let useSpeculative = speculative ?? (self.speculative && speculationPaysOff)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(
                    with: Result { try self.run(userContent: userContent, speculative: useSpeculative) })
            }
        }
    }

    private func run(userContent: String, speculative: Bool) throws -> (text: String, stats: Stats) {
        var stats = Stats()
        let suffix = try session.tokenize(userContent + suffixTemplate, addSpecial: false)
        let maxTokens = CleanupPrompt.maxOutputTokens(forInputTokens: suffix.count)
        stats.promptTokens = suffix.count
        guard prefixLength + suffix.count + maxTokens + 16 < session.contextLength else {
            throw LlamaError.promptTooLong(suffix.count)
        }

        // Drop the previous dictation, keep the cached prefix.
        try session.removeTokens(from: prefixLength)

        let prefillStart = Date()
        try session.decode(suffix, at: prefixLength, allLogits: false)
        let first = session.argmax(at: -1)
        stats.prefillSeconds = Date().timeIntervalSince(prefillStart)

        let generateStart = Date()
        let (tokens, decodeStats) = try session.generate(
            first: first,
            position: prefixLength + suffix.count,
            source: suffix,
            maxTokens: maxTokens,
            speculative: speculative
        )
        stats.generateSeconds = Date().timeIntervalSince(generateStart)
        stats.outputTokens = tokens.count
        stats.decode = decodeStats
        state.withLock { [stats] in $0.lastStats = stats }
        return (session.detokenize(tokens), stats)
    }
}
