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
/// context as a five-minute one. Once the notes get long the model is asked to merge them, so
/// the answer always fits `maxOutputTokens`.
public enum MeetingNotesPrompt {
    /// The notes context, in tokens; the llama runner creates it with this size.
    public static let contextTokens = 6_144
    /// Room for the updated notes.
    public static let maxOutputTokens = 1_200
    /// Notes longer than this are merged down on the next update (about 400 tokens, so the
    /// answer stays well under `maxOutputTokens`).
    public static let compactAfterWords = 300

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
    decision or action item unless the transcript changes or cancels it. Summary bullets carry \
    the facts and numbers that were said: prices, discounts, quantities, dates and deadlines.
    2. When someone corrects themself or the group changes its mind, keep only the final version.
    3. A decision is something the people on the call agreed on. A proposal, a condition ("if we \
    can add the clause"), a guess about someone else ("I think procurement will go for it") or \
    anything still to be checked is an open question or an action item, not a decision.
    4. An action item is anyone's commitment to do something: "I'll send…", "can you update…" \
    "sure", "I'll take it to…". Record every one, from either side of the call, with who does \
    it, who it is for when that was said, and the due date if one was said.
    5. Only write what was said. Never invent names, dates, numbers or tasks. When people name \
    themselves ("Sam here") or You address them by name ("Hi Dana", "thanks, Dana"), use that \
    name rather than "Others"; with only one other person on the call, that is who Others is. \
    The owner of a task is that name, "You" for tasks the note-taker took on, or "Someone".
    6. Bullets are short phrases of at most 15 words. Merge duplicates.
    7. A section with nothing in it has the single bullet "- None yet".
    8. The transcript comes from speech recognition and may have misheard words; use context.

    Example. Transcript:
    [00:10] You: Can we get the venue booked by Friday?
    [00:15] Others: Sam here. I can book it, but only if finance approves the deposit.
    [00:22] You: I'll ask finance today. And let's do the 12th, sorry, the 14th.
    [00:30] Others: The 14th works for me.
    Notes:
    ## Summary
    - Booking the venue for the event on the 14th
    ## Decisions
    - Event is on the 14th
    ## Action items
    - [ ] You: ask finance to approve the deposit (today)
    - [ ] Sam: book the venue once the deposit is approved (by Friday)
    ## Open questions
    - Will finance approve the deposit?
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

    /// The request the app sends for one notes update.
    ///
    /// - Parameters:
    ///   - segments: the new transcript lines, or every line for a `complete` pass.
    ///   - known: everything said so far, for the names on the call.
    ///   - complete: the final pass over a whole meeting. It starts from empty notes rather than
    ///     the running ones, so a slip made early in the meeting can't survive into the final notes.
    ///   - retry: the previous answer failed (often cut off for length), so ask for shorter notes
    ///     than the regular merge does; repeating the same request would get the same answer.
    public static func request(
        notes: String, segments: [MeetingSegment], known: [MeetingSegment], final: Bool, complete: Bool, retry: Bool = false
    ) -> [ChatMessage] {
        let current = complete ? "" : notes
        return messages(
            notes: current, newTranscript: transcriptText(segments), isFinal: final, complete: complete,
            names: names(in: known), compact: retry || MeetingTranscript.wordCount(current) > compactAfterWords,
            retry: retry
        )
    }

    /// - Parameters:
    ///   - complete: the transcript is the whole meeting rather than only what is new.
    ///   - names: people named on the call so far (see `names(in:)`).
    ///   - compact: ask for the notes to be merged down.
    ///   - retry: the last answer to this request was cut off or unusable; ask for much shorter notes.
    public static func messages(
        notes: String, newTranscript: String, isFinal: Bool, complete: Bool = false, names: [String] = [], compact: Bool = false,
        retry: Bool = false
    ) -> [ChatMessage] {
        var content = "<notes>\n\(notes.isEmpty ? emptyNotes : notes)\n</notes>\n"
        if !names.isEmpty {
            content += "People named on the call: \(names.joined(separator: ", ")). Use these names instead of \"Others\" or \"Someone\".\n"
        }
        content += "<transcript>\n\(newTranscript)\n</transcript>"
        if complete {
            content += "\nThe meeting has ended and this is the complete transcript. Write the final notes from it, going through it line by line: every commitment anyone made is an action item with the right owner and recipient, only what was agreed is a decision, and the key numbers and dates are in the summary."
        } else if isFinal {
            content += "\nThe meeting has ended. This is the last part of the transcript; make these the final notes."
        }
        if compact {
            content += "\nThe notes are getting long: merge related bullets into shorter ones, keep the Summary to at most 8 bullets and Open questions to at most 5, and keep every decision and action item that still stands."
        }
        if retry {
            content += "\nYour last answer to this was cut off or not in the format above. Write much shorter notes: at most 5 Summary bullets and 3 Open questions, bullets of at most 10 words, and one action item per owner with that owner's tasks combined."
        }
        return [ChatMessage(role: "system", content: system), ChatMessage(role: "user", content: content)]
    }

    /// Names people used on the call: introductions on the call's side ("Priya here", "This is
    /// Marcus", "Marcus again") and people You address ("Hi Dana", "thanks, Dana", "Marcus, can
    /// you…"). A small model rarely carries these through on its own, so they're listed for it.
    /// The patterns also catch capitalized words that start a sentence ("Same here", "Overall,
    /// how…"), days and months ("It's Thursday") and companies ("It's Acme's"), so those are
    /// filtered out, as is any word that is also said in lower case ("still", "both").
    public static func names(in segments: [MeetingSegment]) -> [String] {
        let name = "([A-Z][a-z]+)"
        let introductions = [
            "\\b\(name) (?:here|again)\\b",
            // "This is Marcus." / "It's Dana from Acme", but not "It's Acme's account" or "This is Google Meet".
            "\\b(?:[Tt]his is|[Ii]t's|I'm) \(name)(?=[.,;!?]|\\s+(?:from|here|speaking|again|with|at|on)\\b|\\s*$)",
        ]
        let addressed = [
            "(?:^|[.!?,;]\\s+)(?:[Hh]i|[Hh]ey|[Hh]ello|[Tt]hanks|[Tt]hank you|[Bb]ye|[Mm]orning),? \(name)\\b",
            "(?:^|[.!?]\\s+)\(name), (?:can|could|would|will|where|what|how|do|did|are|is)\\b",
        ]
        let lowerCaseWords = Set(segments.flatMap { segment in
            segment.text.split { !$0.isLetter }.filter { $0.first?.isLowercase == true }.map(String.init)
        })
        var found: [String] = []
        for segment in segments {
            for pattern in segment.speaker == .others ? introductions : addressed {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let text = segment.text
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let range = Range(match.range(at: 1), in: text) else { continue }
                    let candidate = String(text[range])
                    guard !notNames.contains(candidate), !lowerCaseWords.contains(candidate.lowercased()),
                          !adverbEndings.contains(where: { candidate.hasSuffix($0) }), !found.contains(candidate)
                    else { continue }
                    found.append(candidate)
                }
            }
        }
        return found
    }

    /// Capitalized words those patterns can catch that aren't names.
    private static let notNames: Set<String> = [
        "Morning", "Okay", "Great", "Thanks", "Yes", "No", "Sure", "Fair", "Perfect", "Happy", "Hi",
        "Hello", "Hey", "Sounds", "Also", "Agreed", "Right", "Well", "So", "Good", "Nice", "Everyone",
        "All", "Team", "Guys", "Folks", "Sorry", "Cool", "Noted", "Understood", "Yeah", "Fine",
        "Same", "Exactly", "Absolutely", "Correct", "Definitely", "Totally", "Yep", "Yup", "Nope",
        "Alright", "Now", "Actually", "Anyway", "Honestly", "Wait", "Interesting", "Awesome",
        "Excellent", "Next", "Then", "And", "But", "Or", "Look", "Listen", "Basically", "Oh", "Ah",
        "Um", "Uh", "Hmm", "First", "Second", "Third", "Finally", "Lastly", "Over", "Back", "Out",
        "Nobody", "Somebody", "Someone", "Anyone", "Everybody", "Here", "There", "Again", "Quick",
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "Today",
        "Tomorrow", "Tonight", "January", "February", "March", "April", "May", "June", "July",
        "August", "September", "October", "November", "December", "Overall", "Otherwise", "Still",
        "Not", "Both", "Either", "Neither", "Each", "Just", "Only", "Even", "Maybe", "Perhaps",
        "Instead", "Meanwhile", "However", "Besides", "Plus", "Like", "Yet", "Already", "Ok", "Thank",
    ]

    /// "Realistically, what…", "Hopefully, can…": sentence openers, never names (Emily and Kelly
    /// don't end like this).
    private static let adverbEndings = [
        "ally", "ously", "ately", "ently", "antly", "ctly", "tely", "fully", "ably", "ibly", "edly",
        "ingly", "ckly", "nkly", "stly", "ssly", "rely",
    ]

    /// Transcript lines for the prompt.
    public static func transcriptText(_ segments: [MeetingSegment]) -> String {
        segments.isEmpty ? "(no new speech)" : segments.map(\.line).joined(separator: "\n")
    }

    /// Strips wrappers small models add, and rejects output that isn't complete notes.
    ///
    /// Only headings and bullets are kept, so a closing "Let me know if…" never becomes part of the
    /// notes (and never gets carried into the next update). The last section has to be there:
    /// an answer cut off at the token limit would otherwise silently lose what came after.
    public static func sanitize(_ output: String) -> String? {
        var text = output
        if let range = text.range(of: "</think>") { text = String(text[range.upperBound...]) }
        guard let start = text.range(of: "## Summary", options: .caseInsensitive) else { return nil }
        text = String(text[start.lowerBound...])

        var lines: [String] = []
        for raw in text.split(separator: "\n") {
            let line = raw.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") || trimmed.hasPrefix("- ") {
                lines.append(trimmed)
            } else if line.hasPrefix("  "), !trimmed.isEmpty, !lines.isEmpty, lines.last?.hasPrefix("- ") == true {
                lines[lines.count - 1] += " " + trimmed // a bullet wrapped onto the next line
            }
        }
        let headings = lines.filter { $0.hasPrefix("## ") }.map { $0.lowercased() }
        for required in ["## summary", "## decisions", "## action items", "## open questions"] where !headings.contains(required) {
            return nil
        }
        return lines.joined(separator: "\n")
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
            return await self.run(transcript, final: final)
        }
        inFlight = task
        return await task.value
    }

    private func run(_ transcript: MeetingTranscript, final: Bool) async -> Bool {
        let readAll = final && Self.finalPassReadsEverything(transcript)
        let batches = Self.batches(pending(in: transcript))
        guard readAll || !batches.isEmpty || (final && !notes.isEmpty) else { return false }
        isUpdating = true
        defer { isUpdating = false }

        // A fresh read of the whole meeting; if it fails (too long after all, or a bad answer),
        // finish from the running notes instead.
        if readAll, await fold(transcript.segments, in: transcript, final: true, complete: true) { return true }
        for (index, batch) in (batches.isEmpty ? [[]] : batches).enumerated() {
            let isLast = index == max(0, batches.count - 1)
            guard await fold(batch, in: transcript, final: final && isLast, complete: false) else { return false }
        }
        return true
    }

    /// One update: the current notes plus `segments` in, updated notes out. A failed answer (often
    /// one cut off for length) is retried once, asking for merged notes.
    private func fold(_ segments: [MeetingSegment], in transcript: MeetingTranscript, final: Bool, complete: Bool) async -> Bool {
        if await ask(segments, in: transcript, final: final, complete: complete, retry: false) { return true }
        return await ask(segments, in: transcript, final: final, complete: complete, retry: true)
    }

    private func ask(_ segments: [MeetingSegment], in transcript: MeetingTranscript, final: Bool, complete: Bool, retry: Bool) async -> Bool {
        let messages = MeetingNotesPrompt.request(
            notes: notes, segments: segments, known: transcript.segments, final: final, complete: complete, retry: retry
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
