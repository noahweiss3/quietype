/// The few operations greedy decoding needs from a language model.
public protocol GreedyLanguageModel {
    associatedtype Token: Equatable

    /// Appends `tokens` to the sequence at `position` and returns, for each of them,
    /// the model's most likely next token.
    mutating func evaluate(_ tokens: [Token], at position: Int) throws -> [Token]

    /// Forgets everything from `position` on (rejected draft tokens).
    mutating func truncate(from position: Int) throws

    func isEndOfGeneration(_ token: Token) -> Bool
}

/// Why generation ended. Only `.endOfGeneration` means the model finished its answer; stopping
/// at the token limit means the answer was cut off.
public enum GenerationStop: Sendable {
    case endOfGeneration
    case tokenLimit
}

public struct DecodeStats: Equatable, Sendable {
    public var forwardPasses = 0
    public var draftedTokens = 0
    public var acceptedTokens = 0
    public var stop = GenerationStop.endOfGeneration

    public init() {}
}

public enum SpeculativeDecoder {
    /// Greedy generation, optionally speeding it up with prompt-lookup drafts.
    ///
    /// Draft length adapts as it goes: it grows while drafts are fully accepted (copying a long
    /// stretch of the input) and shrinks after misses (the model is rewriting), so a list or a
    /// correction doesn't pay for long drafts that keep getting thrown away.
    ///
    /// - Parameters:
    ///   - next: the model's prediction after the prompt (already evaluated up to `position`).
    ///   - source: tokens to draft from, usually the dictation.
    /// - Returns: generated tokens, without the end-of-generation token; `stats.stop` says whether
    ///   the model ended its answer or ran into `maxTokens`.
    public static func generate<Model: GreedyLanguageModel>(
        model: inout Model,
        next first: Model.Token,
        position start: Int,
        source: [Model.Token],
        maxTokens: Int,
        speculative: Bool = true,
        drafter initial: PromptLookupDrafter = PromptLookupDrafter()
    ) throws -> (tokens: [Model.Token], stats: DecodeStats) {
        var drafter = initial
        var stats = DecodeStats()
        var output: [Model.Token] = []
        var next = first
        var position = start
        let longest = max(1, drafter.maxDraft)
        var draftLimit = min(4, longest)

        while output.count < maxTokens, !model.isEndOfGeneration(next) {
            output.append(next)
            // At the limit this still evaluates the last token, without a draft: one more pass
            // tells an answer that ends exactly at `maxTokens` from one that was cut off.
            var draft = speculative && output.count < maxTokens ? drafter.draft(generated: output, source: source) : []
            draft = Array(draft.prefix(min(draftLimit, maxTokens - output.count)))

            let predictions = try model.evaluate([next] + draft, at: position)
            stats.forwardPasses += 1
            stats.draftedTokens += draft.count

            // predictions[i] is what the model wants after token i of the batch. Keep drafted
            // tokens while they match what the model would have produced on its own.
            var accepted = 0
            var prediction = predictions[0]
            while accepted < draft.count, prediction == draft[accepted], !model.isEndOfGeneration(prediction) {
                output.append(prediction)
                accepted += 1
                prediction = predictions[accepted]
            }
            drafter.accept(accepted)
            stats.acceptedTokens += accepted
            position += 1 + accepted
            if accepted < draft.count { try model.truncate(from: position) }
            next = prediction

            if !draft.isEmpty {
                if accepted == draft.count, draft.count == draftLimit {
                    draftLimit = min(longest, draftLimit * 2)
                } else if accepted == 0 {
                    draftLimit = max(2, draftLimit / 2)
                }
            }
        }
        stats.stop = model.isEndOfGeneration(next) ? .endOfGeneration : .tokenLimit
        return (output, stats)
    }
}
