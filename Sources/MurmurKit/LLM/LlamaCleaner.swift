import Foundation
import llama
import MurmurCore

/// The on-device cleanup LLM.
///
/// At load time the fixed part of the prompt (system prompt and examples) is evaluated once and
/// stays in the KV cache. Each dictation then only evaluates its own short suffix and generates
/// with prompt-lookup speculative decoding.
public final class LlamaCleaner: TextCleaner, @unchecked Sendable {
    public struct Stats: Sendable {
        public var promptTokens = 0
        public var outputTokens = 0
        public var decode = DecodeStats()
        public var prefillSeconds = 0.0
        public var generateSeconds = 0.0
    }

    public let model: CleanupModel
    private let session: LlamaSession
    private let queue = DispatchQueue(label: "murmur.llama", qos: .userInitiated)
    private let prefixLength: Int
    private let suffixTemplate: String

    /// Turn off to compare against plain greedy decoding.
    public var speculative = true
    public private(set) var lastStats = Stats()

    /// Time to evaluate 8 tokens at once divided by the time for 1, measured at load.
    /// Speculation only pays off when a small batch costs about the same as a single token,
    /// which holds on Apple Silicon GPUs but not on, say, a virtual machine's GPU.
    public private(set) var batchCostRatio = 1.0
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

    private static func measureBatchCost(_ session: LlamaSession, at position: Int, using tokens: [llama_token]) -> Double {
        func fastest(_ count: Int) -> Double {
            var best = Double.infinity
            for _ in 0..<3 {
                let started = Date()
                guard (try? session.decode(Array(tokens.suffix(count)), at: position, allLogits: true)) != nil else { return .infinity }
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
        let layers = gpuLayers ?? ProcessInfo.processInfo.environment["MURMUR_GPU_LAYERS"].flatMap(Int32.init) ?? 999
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try LlamaCleaner(model: model, session: LlamaSession(modelPath: path.path, gpuLayers: layers))
                })
            }
        }
    }

    public func clean(_ dictation: String, style: WritingStyle, vocabulary: [String]) async throws -> String {
        let content = CleanupPrompt.userContent(dictation: dictation, style: style, vocabulary: vocabulary)
        return try await complete(userContent: content).text
    }

    /// Runs one cleanup from a fully built user message. Exposed for tests and benchmarks.
    /// `speculative` forces speculation on or off; by default it follows the setting and the
    /// load-time measurement.
    public func complete(userContent: String, speculative: Bool? = nil) async throws -> (text: String, stats: Stats) {
        let useSpeculative = speculative ?? (self.speculative && speculationPaysOff)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.run(userContent: userContent, speculative: useSpeculative) })
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
        var greedy = LlamaGreedyModel(session: session)
        let (tokens, decodeStats) = try SpeculativeDecoder.generate(
            model: &greedy,
            next: first,
            position: prefixLength + suffix.count,
            source: suffix,
            maxTokens: maxTokens,
            speculative: speculative
        )
        stats.generateSeconds = Date().timeIntervalSince(generateStart)
        stats.outputTokens = tokens.count
        stats.decode = decodeStats
        lastStats = stats
        return (session.detokenize(tokens), stats)
    }
}
