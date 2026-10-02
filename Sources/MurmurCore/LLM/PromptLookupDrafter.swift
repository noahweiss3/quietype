/// Draft tokens for speculative decoding, taken from the prompt itself.
///
/// Cleanup output is mostly a copy of the dictation, so after the model writes a few tokens we
/// can usually find them in the input and guess that the next tokens are the ones that followed
/// there. The model then checks the whole guess in one forward pass and keeps the prefix it agrees
/// with. With greedy decoding the result is identical to decoding one token at a time.
public struct PromptLookupDrafter: Sendable {
    public var maxNgram: Int
    public var maxDraft: Int

    /// Where the last accepted draft ended in the source, so a copy keeps moving forward
    /// instead of jumping back to an earlier occurrence of a common n-gram.
    private var cursor = 0
    private var lastDraftStart = 0

    public init(maxNgram: Int = 3, maxDraft: Int = 10) {
        self.maxNgram = maxNgram
        self.maxDraft = maxDraft
    }

    /// Returns up to `maxDraft` tokens predicted to follow `generated`, looked up in `source`.
    public mutating func draft<T: Equatable>(generated: [T], source: [T]) -> [T] {
        guard !generated.isEmpty, !source.isEmpty else { return [] }

        for n in stride(from: min(maxNgram, generated.count), through: 1, by: -1) {
            let tail = generated.suffix(n)
            var best: Int?
            var start = 0
            while start + n < source.count {
                if source[start..<(start + n)].elementsEqual(tail) {
                    let end = start + n
                    if end >= cursor { best = end; break }
                    best = best ?? end
                }
                start += 1
            }
            // Single-token matches are weak evidence; only trust them when they move forward.
            if let end = best, n > 1 || end >= cursor {
                lastDraftStart = end
                return Array(source[end..<min(source.count, end + maxDraft)])
            }
        }
        return []
    }

    /// Records how many tokens of the last draft the model kept.
    public mutating func accept(_ count: Int) {
        if count > 0 { cursor = lastDraftStart + count }
    }
}
