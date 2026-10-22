import Foundation

/// Free-form generation with the local LLM. Implemented on macOS by the llama.cpp runner.
public protocol TextGenerator: Sendable {
    func generate(_ messages: [ChatMessage], maxTokens: Int) async throws -> String
}

/// Keeps the notes for one meeting and folds new transcript into them.
public actor MeetingNotesWriter {
    public private(set) var notes = ""
    public private(set) var updates = 0
    public private(set) var lastError: String?
    public private(set) var isUpdating = false

    private let generator: TextGenerator
    /// Segments already reflected in the notes. Tracked by id rather than position because a
    /// late segment can land before ones that were already covered.
    private var covered = Set<Int>()
    private var inFlight: Task<Bool, Never>?

    /// Longer backlogs are folded in over several requests so each prompt stays small.
    public static let maxWordsPerUpdate = 900

    /// Meetings up to this many words are re-read in full for the final notes. Worked out from
    /// the notes context: what is left after the answer and about 1,200 tokens for the system
    /// prompt, the request text and margin, at about 1.7 tokens per transcript word including the
    /// "[mm:ss] Speaker:" prefixes. If a pass still doesn't fit, `run` falls back to finishing
    /// incrementally.
    public static let fullFinalPassWords =
        (MeetingNotesPrompt.contextTokens - MeetingNotesPrompt.maxOutputTokens - 1_200) * 10 / 17

    public static func finalPassReadsEverything(_ transcript: MeetingTranscript) -> Bool {
        !transcript.segments.isEmpty && transcript.wordCount <= fullFinalPassWords
    }

    public init(generator: TextGenerator) {
        self.generator = generator
    }

    public func pending(in transcript: MeetingTranscript) -> [MeetingSegment] {
        transcript.segments.filter { !covered.contains($0.id) }
    }

    public func pendingWords(in transcript: MeetingTranscript) -> Int {
        pending(in: transcript).reduce(0) { $0 + MeetingTranscript.wordCount($1.text) }
    }

    /// Folds everything not yet covered into the notes. Calls queue behind one in progress.
    /// `final` also runs when nothing is new, to tidy the notes once the meeting ends.
    @discardableResult
    public func update(with transcript: MeetingTranscript, final: Bool = false) async -> Bool {
        let previous = inFlight
        let task = Task { () -> Bool in
            _ = await previous?.value
            return await self.run(transcript, isFinal: final)
        }
        inFlight = task
        return await task.value
    }

    private func run(_ transcript: MeetingTranscript, isFinal: Bool) async -> Bool {
        let readAll = isFinal && Self.finalPassReadsEverything(transcript)
        let batches = Self.batches(pending(in: transcript))
        guard readAll || !batches.isEmpty || (isFinal && !notes.isEmpty) else { return false }
        isUpdating = true
        defer { isUpdating = false }

        // A fresh read of the whole meeting; if it fails (too long after all, or a bad answer),
        // finish from the running notes instead.
        if readAll, await fold(transcript.segments, in: transcript, isFinal: true, complete: true) { return true }
        for (index, batch) in (batches.isEmpty ? [[]] : batches).enumerated() {
            let isLast = index == max(0, batches.count - 1)
            guard await fold(batch, in: transcript, isFinal: isFinal && isLast, complete: false) else { return false }
        }
        return true
    }

    /// One update: the current notes plus `segments` in, updated notes out. A failed answer (often
    /// one cut off for length) is retried once, asking for merged notes.
    private func fold(
        _ segments: [MeetingSegment], in transcript: MeetingTranscript, isFinal: Bool, complete: Bool
    ) async -> Bool {
        if await ask(segments, in: transcript, isFinal: isFinal, complete: complete, retry: false) { return true }
        return await ask(segments, in: transcript, isFinal: isFinal, complete: complete, retry: true)
    }

    private func ask(
        _ segments: [MeetingSegment], in transcript: MeetingTranscript, isFinal: Bool, complete: Bool, retry: Bool
    ) async -> Bool {
        let messages = MeetingNotesPrompt.request(
            notes: notes, segments: segments, known: transcript.segments, isFinal: isFinal, complete: complete,
            retry: retry
        )
        do {
            let output = try await generator.generate(messages, maxTokens: MeetingNotesPrompt.maxOutputTokens)
            guard let cleaned = MeetingNotesPrompt.sanitize(output) else {
                lastError = "notes update was not in the notes format: \(output.prefix(120))"
                return false
            }
            notes = cleaned
            covered.formUnion(segments.map(\.id))
            updates += 1
            lastError = nil
            return true
        } catch {
            lastError = "\(error)"
            return false
        }
    }

    /// Splits segments into consecutive batches of at most `maxWordsPerUpdate` words.
    public static func batches(_ segments: [MeetingSegment]) -> [[MeetingSegment]] {
        var batches: [[MeetingSegment]] = []
        var current: [MeetingSegment] = []
        var words = 0
        for segment in segments {
            let count = MeetingTranscript.wordCount(segment.text)
            if !current.isEmpty, words + count > maxWordsPerUpdate {
                batches.append(current)
                current = []
                words = 0
            }
            current.append(segment)
            words += count
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }
}
