import Foundation

/// Free-form generation with the local LLM. Implemented on macOS by the llama.cpp runner.
public protocol TextGenerator: Sendable {
    func generate(_ messages: [ChatMessage], maxTokens: Int) async throws -> String
}

/// The prompt for live meeting notes.
///
/// Notes are updated incrementally: the model sees the current notes plus only the transcript
/// that came in since the last update, and returns the full updated notes. That keeps every
/// request small, so notes stay current during the meeting and a two-hour call fits the same
/// context as a five-minute one.
public enum MeetingNotesPrompt {
    public static let system = """
    You keep live notes for a meeting while it happens. You receive the current notes inside \
    <notes> tags and the newest part of the transcript inside <transcript> tags. Each transcript \
    line is "[mm:ss] Speaker: text". "You" is the person taking the notes; "Others" is everyone \
    else on the call.

    Output the complete updated notes in exactly this format and nothing else:

    ## Summary
    - one short bullet per topic, most important first
    ## Decisions
    - what was agreed
    ## Action items
    - [ ] Owner: task (due date, if one was said)
    ## Open questions
    - questions raised but not settled

    Rules:
    1. Keep everything in the current notes that is still true and add what is new. Never drop a \
    decision or action item unless the transcript changes or cancels it.
    2. When someone corrects themself or the group changes its mind, keep only the final version.
    3. Only write what was said. Never invent names, dates, numbers or tasks. The owner of a task \
    is the name that was said, "You" for tasks the note-taker took on, or "Someone" if unclear.
    4. Bullets are short phrases of at most 15 words. Merge duplicates.
    5. A section with nothing in it has the single bullet "- None yet".
    6. The transcript comes from speech recognition and may have misheard words; use context.
    """

    public static let emptyNotes = """
    ## Summary
    - None yet
    ## Decisions
    - None yet
    ## Action items
    - None yet
    ## Open questions
    - None yet
    """

    public static func messages(notes: String, newTranscript: String, isFinal: Bool) -> [ChatMessage] {
        var content = "<notes>\n\(notes.isEmpty ? emptyNotes : notes)\n</notes>\n<transcript>\n\(newTranscript)\n</transcript>"
        if isFinal {
            content += "\nThe meeting has ended. This is the last part of the transcript; make these the final notes."
        }
        return [ChatMessage(role: "system", content: system), ChatMessage(role: "user", content: content)]
    }

    /// Transcript lines for the prompt.
    public static func transcriptText(_ segments: [MeetingSegment]) -> String {
        segments.isEmpty ? "(no new speech)" : segments.map(\.line).joined(separator: "\n")
    }

    /// Notes are short; this leaves room for a long meeting's worth of bullets.
    public static let maxOutputTokens = 900

    /// Strips wrappers small models add, and rejects output that isn't notes.
    public static func sanitize(_ output: String) -> String? {
        var text = output
        if let range = text.range(of: "</think>") { text = String(text[range.upperBound...]) }
        text = text.replacingOccurrences(of: "```markdown", with: "").replacingOccurrences(of: "```", with: "")
        for tag in ["<notes>", "</notes>"] { text = text.replacingOccurrences(of: tag, with: "") }
        guard let start = text.range(of: "## Summary", options: .caseInsensitive) else { return nil }
        text = String(text[start.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: "## Action items", options: .caseInsensitive) != nil else { return nil }
        return text
    }
}

/// When to refresh the notes: after enough new talk, but not more often than the model can keep
/// up with. A burst of talk gets an update sooner.
public struct MeetingNotesSchedule: Sendable {
    public var minNewWords: Int
    public var minInterval: TimeInterval
    public var burstWords: Int

    public init(minNewWords: Int = 60, minInterval: TimeInterval = 45, burstWords: Int = 350) {
        self.minNewWords = minNewWords
        self.minInterval = minInterval
        self.burstWords = burstWords
    }

    public func isDue(pendingWords: Int, secondsSinceLastUpdate: TimeInterval) -> Bool {
        pendingWords >= burstWords || (pendingWords >= minNewWords && secondsSinceLastUpdate >= minInterval)
    }
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
            return await self.run(transcript, final: final)
        }
        inFlight = task
        return await task.value
    }

    private func run(_ transcript: MeetingTranscript, final: Bool) async -> Bool {
        let batches = Self.batches(pending(in: transcript))
        guard !batches.isEmpty || (final && !notes.isEmpty) else { return false }
        isUpdating = true
        defer { isUpdating = false }

        for (index, batch) in (batches.isEmpty ? [[]] : batches).enumerated() {
            let isLast = index == max(0, batches.count - 1)
            let text = MeetingNotesPrompt.transcriptText(batch)
            let messages = MeetingNotesPrompt.messages(notes: notes, newTranscript: text, isFinal: final && isLast)
            do {
                let output = try await generator.generate(messages, maxTokens: MeetingNotesPrompt.maxOutputTokens)
                guard let cleaned = MeetingNotesPrompt.sanitize(output) else {
                    lastError = "notes update was not in the notes format: \(output.prefix(120))"
                    return false
                }
                notes = cleaned
                covered.formUnion(batch.map(\.id))
                updates += 1
                lastError = nil
            } catch {
                lastError = "\(error)"
                return false
            }
        }
        return true
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
