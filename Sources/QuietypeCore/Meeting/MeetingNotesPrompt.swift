import Foundation

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
    ///   - notes: the running notes, empty before the first update. Past `compactAfterWords` the
    ///     model is asked to merge them down.
    ///   - segments: the new transcript lines, or every line for a `complete` pass.
    ///   - known: everything said so far, for the names on the call.
    ///   - isFinal: the meeting has ended and these are the last lines, so these become the final notes.
    ///   - complete: the final pass over a whole meeting. It starts from empty notes rather than
    ///     the running ones, so a slip made early in the meeting can't survive into the final notes.
    ///   - retry: the previous answer failed (often cut off for length), so ask for shorter notes
    ///     than the regular merge does; repeating the same request would get the same answer.
    public static func request(
        notes: String, segments: [MeetingSegment], known: [MeetingSegment], isFinal: Bool, complete: Bool,
        retry: Bool = false
    ) -> [ChatMessage] {
        let current = complete ? "" : notes
        return messages(
            notes: current, newTranscript: transcriptText(segments), isFinal: isFinal, complete: complete,
            names: names(in: known), compact: retry || MeetingTranscript.wordCount(current) > compactAfterWords,
            retry: retry
        )
    }

    /// The user message for one notes update, from parts `request` has already worked out.
    ///
    /// - Parameters:
    ///   - notes: the current notes; empty means none yet.
    ///   - newTranscript: the transcript lines to fold in, as `transcriptText` writes them.
    ///   - isFinal: the meeting has ended, so these are the final notes.
    ///   - complete: the transcript is the whole meeting rather than only what is new.
    ///   - names: people named on the call so far (see `names(in:)`).
    ///   - compact: ask for the notes to be merged down.
    ///   - retry: the last answer to this request was cut off or unusable; ask for much shorter notes.
    public static func messages(
        notes: String, newTranscript: String, isFinal: Bool, complete: Bool = false, names: [String] = [],
        compact: Bool = false,
        retry: Bool = false
    ) -> [ChatMessage] {
        var content = "<notes>\n\(notes.isEmpty ? emptyNotes : notes)\n</notes>\n"
        if !names.isEmpty {
            content +=
                "People named on the call: \(names.joined(separator: ", ")). "
                + "Use these names instead of \"Others\" or \"Someone\".\n"
        }
        content += "<transcript>\n\(newTranscript)\n</transcript>"
        if complete {
            content +=
                "\nThe meeting has ended and this is the complete transcript. Write the final notes from it, "
                + "going through it line by line: every commitment anyone made is an action item with the right owner "
                + "and recipient, only what was agreed is a decision, and the key numbers and dates are in the summary."
        } else if isFinal {
            content += "\nThe meeting has ended. This is the last part of the transcript; make these the final notes."
        }
        if compact {
            content +=
                "\nThe notes are getting long: merge related bullets into shorter ones, keep the Summary to at "
                + "most 8 bullets and Open questions to at most 5, and keep every decision and action item that "
                + "still stands."
        }
        if retry {
            content +=
                "\nYour last answer to this was cut off or not in the format above. Write much shorter notes: "
                + "at most 5 Summary bullets and 3 Open questions, bullets of at most 10 words, and one action "
                + "item per owner with that owner's tasks combined."
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
        let lowerCaseWords = Set(
            segments.flatMap { segment in
                segment.text.split { !$0.isLetter }.filter { $0.first?.isLowercase == true }.map(String.init)
            })
        var found: [String] = []
        for segment in segments {
            for regex in segment.speaker == .others ? introductions : addressed {
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

    /// A capitalized word: group 1 of the patterns below.
    private static let namePattern = "([A-Z][a-z]+)"

    private static let introductions = [
        "\\b\(namePattern) (?:here|again)\\b",
        // "This is Marcus." / "It's Dana from Acme", but not "It's Acme's account" or "This is Google Meet".
        "\\b(?:[Tt]his is|[Ii]t's|I'm) \(namePattern)(?=[.,;!?]|\\s+(?:from|here|speaking|again|with|at|on)\\b|\\s*$)",
    ].map { try! NSRegularExpression(pattern: $0) }

    private static let addressed = [
        "(?:^|[.!?,;]\\s+)(?:[Hh]i|[Hh]ey|[Hh]ello|[Tt]hanks|[Tt]hank you|[Bb]ye|[Mm]orning),? \(namePattern)\\b",
        "(?:^|[.!?]\\s+)\(namePattern), (?:can|could|would|will|where|what|how|do|did|are|is)\\b",
    ].map { try! NSRegularExpression(pattern: $0) }

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
        let sections = ["## summary", "## decisions", "## action items", "## open questions"]
        for required in sections where !headings.contains(required) {
            return nil
        }
        return lines.joined(separator: "\n")
    }
}
