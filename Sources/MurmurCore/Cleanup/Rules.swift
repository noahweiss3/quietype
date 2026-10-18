import Foundation

/// Why a transcript needs the LLM pass. If a transcript has none of these, the rules pass alone
/// is good enough and we skip the LLM, which keeps most dictations at transcription speed.
public enum CleanupCue: String, Codable, Sendable, CaseIterable {
    /// "scratch that", "no wait", "I mean", ... the speaker revised something.
    case correction
    /// "first ... second ...", "bullet point", "the following" ... enumerated items.
    case list
    /// "new line", "new paragraph", spoken punctuation.
    case formatting
    /// Fillers the rules can't safely remove alone: "you know", "like", "sort of".
    case filler
}

public struct RulesResult: Equatable, Sendable {
    public var text: String
    public var cues: Set<CleanupCue>

    public var needsLLM: Bool { !cues.isEmpty }
}

/// Fast deterministic cleanup that runs on every dictation, with or without the LLM.
/// It is deliberately conservative: anything that needs judgement is left for the LLM and
/// flagged with a cue instead.
public enum Rules {
    public static func apply(_ raw: String) -> RulesResult {
        var text = raw.replacingOccurrences(of: "\n", with: " ").collapsingSpaces
        text = applyStartOver(text)
        var words = Words.split(text)
        words = removeFillers(words)
        words = collapseStutters(words)
        text = applyTrailingRetraction(Words.join(words))
        return RulesResult(text: text, cues: detectCues(text))
    }

    // MARK: Start over

    // "Start over" only counts as a command when it stands alone as a clause, so
    // "we had to start over on the design" is left alone (it still raises a cue for the LLM).
    private static let startOver = try! NSRegularExpression(
        pattern: #"(?:^|(?<=[.!?,;:]))\s*(?:(?:ok(?:ay)?|so|um+|uh+|actually|no|sorry|wait)[,.]?\s+)*(?:let me |let's |let us |i'll |i want to |i'm going to |gonna )?(?:start over|start again|start from scratch|begin again)(?:[.!?,;:]+|\s*$)"#,
        options: [.caseInsensitive]
    )

    /// Drops everything up to and including the last standalone "start over".
    static func applyStartOver(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        guard let last = startOver.matches(in: text, range: range).last,
              let end = Range(last.range, in: text)?.upperBound else { return text }
        var rest = Words.split(String(text[end...]))
        if !rest.isEmpty { rest[0].capitalize() }
        return Words.join(rest)
    }

    // MARK: Trailing retraction

    // "… Scratch that." as the last sentence takes back the sentence before it. Earlier in a
    // dictation the command can be followed by what to keep instead ("scratch that, not the
    // wings"), so that is left to the LLM.
    private static let trailingRetraction = try! NSRegularExpression(
        pattern: #"(?:^|(?<=[.!?]))\s*(?:(?:oh|no|wait|actually|sorry|ok(?:ay)?)[,.]?\s+)*(?:scratch that|scrap that|strike that|delete that|never ?mind|i take that back|forget that|forget it)[.!]*\s*$"#,
        options: [.caseInsensitive]
    )

    /// Drops a closing "scratch that" together with the sentence it refers to.
    static func applyTrailingRetraction(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = trailingRetraction.firstMatch(in: text, range: range),
              let command = Range(match.range, in: text) else { return text }
        var words = Words.split(String(text[..<command.lowerBound]))
        var start = words.count
        while start > 0, start == words.count || !words[start - 1].endsSentence { start -= 1 }
        words.removeSubrange(start...)
        return Words.join(words)
    }

    // MARK: Fillers

    static let fillers: Set<String> = ["um", "umm", "ummm", "uh", "uhh", "uhhh", "uhm", "erm", "er", "hmm", "hm", "mm"]

    // A comma after one of these is real ("So, we ..."); after other words it was only there
    // because the transcriber punctuated the pause around a filler ("I was, um, thinking").
    private static let discourseMarkers: Set<String> = [
        "so", "well", "okay", "ok", "yeah", "yes", "no", "right", "oh", "hey", "hi", "hello",
        "anyway", "anyways", "also", "now", "alright", "sure", "thanks", "first", "second", "then",
    ]

    static func removeFillers(_ input: [Word]) -> [Word] {
        var out: [Word] = []
        var capitalizeNext = false
        var carryLeading = ""

        for (index, word) in input.enumerated() {
            let isAllCaps = word.core.count > 1 && word.core == word.core.uppercased()
            guard fillers.contains(word.lower), !isAllCaps else {
                var kept = word
                kept.leading = carryLeading + kept.leading
                carryLeading = ""
                if capitalizeNext { kept.capitalize(); capitalizeNext = false }
                out.append(kept)
                continue
            }

            let sentenceStart = out.isEmpty || out.last!.endsSentence
            if sentenceStart && (word.isCapitalized || index == 0) { capitalizeNext = true }
            carryLeading += word.leading

            if var previous = out.popLast() {
                let terminal = word.trailing.filter { ".!?".contains($0) }
                if !terminal.isEmpty, !previous.endsSentence {
                    // "... the end, um." → "... the end."
                    previous.trailing = previous.trailing.filter { !",;:".contains($0) } + terminal
                    capitalizeNext = true
                } else if previous.trailing.hasSuffix(","), !discourseMarkers.contains(previous.lower) {
                    previous.trailing.removeLast()
                }
                out.append(previous)
            }
        }
        return out
    }

    // MARK: Stutters

    // Words people repeat on purpose, so "very very" or "had had" survive.
    private static let intentionalRepeats: Set<String> = [
        "had", "that", "is", "very", "really", "so", "no", "yes", "yeah", "bye", "ha", "haha",
        "hey", "more", "far", "many", "much", "again", "ok", "okay", "go", "knock", "there",
        "well", "now", "please", "do", "can", "blah", "hip", "tick", "chop", "wait", "come",
    ]

    static func collapseStutters(_ input: [Word]) -> [Word] {
        var out: [Word] = []
        for word in input {
            if let previous = out.last,
               previous.lower == word.lower,
               previous.trailing.isEmpty || previous.trailing == ",",
               word.leading.isEmpty,
               word.core.contains(where: \.isLetter),
               !intentionalRepeats.contains(word.lower) {
                var replacement = word
                if previous.isCapitalized { replacement.capitalize() }
                replacement.leading = previous.leading
                out[out.count - 1] = replacement
                continue
            }
            out.append(word)
        }
        return out
    }

    // MARK: Cues

    private static let cuePatterns: [(CleanupCue, NSRegularExpression)] = [
        (.correction, #"\b(scratch that|scrap that|strike that|delete that|cancel that|undo that|take that back|never ?mind|no,? wait|wait,? no|i mean|i meant|actually|sorry|correction|better yet|make that|change that|on second thought|i misspoke|let me correct|let me rephrase|rephrase that|start over|start again|scratch|scrap)\b"#),
        // Narrower forms of words that are usually ordinary text: "…, or rather Wednesday",
        // "…, and make it 4", "…Kestrel instead.", "the parser, no, the lexer".
        (.correction, #"(?:\bor|[,;])\s+rather\b|(?:^|[,.;!?]\s+)(?:and\s+)?make it\b|\binstead(?=\s*[.,;!?]|\s*$)|[,;]\s+no,\s"#),
        // A false start that breaks off after an article or preposition: "Can we push the, I'd like…".
        (.correction, #"\b(?:the|a|an|to|of|for|with|my|our|your|their),\s"#),
        // A revision aimed at something just said: "…, skip the butter", "…. Not Jordan.", "…, just
        // marketing", "…. Oh, and drinks". It has to follow a pause, so "skip the intro" at the start
        // or "we decided to drop it" mid-sentence don't count.
        (.correction, #"[,.;!?]\s+(?:(?:oh|ok(?:ay)?|wait|actually|and|so|no|hmm|but|also)[,.]?\s+)*(?:drop|skip|forget|ignore|remove|delete|cut|lose|take out|take off|leave out|leave off|minus|without|except|exclude|not|just|only|and also|add)\b"#),
        (.correction, #"(?:^|[,.;!?]\s*)(?:oh,? )?wait[,.!]"#),
        (.list, #"\b(first(ly)?\b.*\bsecond(ly)?|number one\b.*\bnumber two|bullet( point)?s?|numbered list|bulleted list|to-?do list|the following|next item|item one)\b"#),
        (.list, #"(^|\s)(one|1)[,.:)]\s.*\s(two|2)[,.:)]\s"#),
        (.filler, #"\byou know\b|\bsort of\b|\b(was|were|is|it's|and|just|so|but|um|uh),? like,? \b|, like,"#),
        (.formatting, #"\b(new ?line|new paragraph|next line|open quote|close quote|end quote|open paren(thesis)?|close paren(thesis)?|all caps|semicolon|exclamation (point|mark)|question mark|em dash)\b"#),
    ].map { cue, pattern in (cue, try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) }

    static func detectCues(_ text: String) -> Set<CleanupCue> {
        let range = NSRange(text.startIndex..., in: text)
        var cues: Set<CleanupCue> = []
        for (cue, regex) in cuePatterns where regex.firstMatch(in: text, range: range) != nil {
            cues.insert(cue)
        }
        return cues
    }

    // MARK: Fallback corrections

    private static let scratchVerbs: Set<String> = ["scratch", "scrap", "strike", "delete", "cancel", "undo"]

    /// A best-effort, no-LLM version of "scratch that", used when the LLM is off or its answer
    /// was rejected. After a full sentence it drops that sentence; mid-sentence it drops the
    /// word right before the command ("at 3, scratch that, 4" → "at 4").
    public static func applyFallbackCorrections(_ text: String) -> String {
        var words = Words.split(text)
        var index = 0
        while index + 1 < words.count {
            let isCommand = scratchVerbs.contains(words[index].lower) && words[index + 1].lower == "that"
                && words[index].leading.isEmpty
            let previous = index > 0 ? words[index - 1] : nil
            let standsAlone = previous == nil || !previous!.trailing.isEmpty
            guard isCommand, standsAlone else { index += 1; continue }

            var removeFrom = index
            if let previous {
                if previous.endsSentence {
                    removeFrom = index - 1
                    while removeFrom > 0, !words[removeFrom - 1].endsSentence { removeFrom -= 1 }
                } else {
                    removeFrom = index - 1
                }
            }
            let afterCommand = words[index + 1].endsSentence
            words.removeSubrange(removeFrom...(index + 1))
            if removeFrom < words.count, removeFrom == 0 || afterCommand || words[removeFrom - 1].endsSentence {
                words[removeFrom].capitalize()
            }
            index = removeFrom
        }
        return Words.join(words)
    }
}
