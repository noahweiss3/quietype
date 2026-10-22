import Foundation
import QuietypeCore
import llama

/// Free-form generation on the cleanup model, used for meeting notes. Made by
/// `LlamaCleaner.makeGenerator()`, which shares the model's weights and queue.
///
/// `@unchecked Sendable` is sound because `session` is only touched on `queue`, the cleaner's
/// serial queue (so the two never run llama calls at once either), and nothing else changes
/// after `init`.
public final class LlamaGenerator: TextGenerator, @unchecked Sendable {
    private let session: LlamaSession
    private let queue: DispatchQueue
    private let assistantPrefill: String
    private let speculative: Bool

    init(session: LlamaSession, queue: DispatchQueue, assistantPrefill: String, speculative: Bool) {
        self.session = session
        self.queue = queue
        self.assistantPrefill = assistantPrefill
        self.speculative = speculative
    }

    public func generate(_ messages: [ChatMessage], maxTokens: Int) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.run(messages, maxTokens: maxTokens) })
            }
        }
    }

    private func run(_ messages: [ChatMessage], maxTokens: Int) throws -> String {
        let prompt = try session.applyTemplate(messages, addAssistant: true) + assistantPrefill
        let tokens = try session.tokenize(prompt, addSpecial: true)
        guard tokens.count + maxTokens + 16 < session.contextLength else {
            throw LlamaError.promptTooLong(tokens.count)
        }
        try session.removeTokens(from: 0)
        try session.decode(tokens, at: 0, allLogits: false)
        // Updated notes repeat much of the current notes, so drafting from the prompt pays off.
        let (output, stats) = try session.generate(
            first: session.argmax(at: -1),
            position: tokens.count,
            source: tokens,
            maxTokens: maxTokens,
            speculative: speculative
        )
        guard stats.stop == .endOfGeneration else { throw LlamaError.outputTruncated(maxTokens) }
        return session.detokenize(output)
    }
}
