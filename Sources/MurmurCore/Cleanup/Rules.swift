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
        text = dropOpeningCommand(text)
        var words = Words.split(text)
        let pausedCorrection = words.indices.contains { isNumberCorrectionPause(words, at: $0) }
        words = removeFillers(words)
        words = collapseStutters(words)
        text = applyTrailingRetraction(Words.join(words))
        var cues = detectCues(text)
        if pausedCorrection { cues.insert(.correction) }
        return RulesResult(text: text, cues: cues)
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

    // MARK: Opening command

    // "Let me rephrase." or "Scratch that." at the very start refers to something outside this
    // dictation, so the command itself is all there is to drop.
    private static let openingCommand = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:ok(?:ay)?|so|um+|uh+|sorry|actually|no)[,.]?\s+)*(?:let me rephrase(?: that)?|scratch that|scrap that|strike that|delete that)[.!,:;]+\s*(?=\S)"#,
        options: [.caseInsensitive]
    )

    static func dropOpeningCommand(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = openingCommand.firstMatch(in: text, range: range),
              let command = Range(match.range, in: text) else { return text }
        var rest = Words.split(String(text[command.upperBound...]))
        if !rest.isEmpty { rest[0].capitalize() }
        return Words.join(rest)
    }

    // MARK: Trailing retraction

    // "… Scratch that." as the last sentence takes back the sentence before it. Earlier in a
    // dictation the command can be followed by what to keep instead ("scratch that, not the
    // wings"), so that is left to the LLM. On its own ("Never mind.", "Forget it.") it is the
    // message, not a command.
    private static let trailingRetraction = try! NSRegularExpression(
        pattern: #"(?<=[.!?])\s*(?:(?:oh|no|wait|actually|sorry|ok(?:ay)?)[,.]?\s+)*(?:scratch that|scrap that|strike that|delete that|never ?mind|i take that back|forget that|forget it)[.!]*\s*$"#,
        options: [.caseInsensitive]
    )

    /// Drops a closing "scratch that" together with the sentence it refers to.
    static func applyTrailingRetraction(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = trailingRetraction.firstMatch(in: text, range: range),
              let command = Range(match.range, in: text) else { return text }
        var words = Words.split(String(text[..<command.lowerBound]))
        var start = words.count
        while start > 0, start == words.count || !endsSentence(words[start - 1]) { start -= 1 }
        words.removeSubrange(start...)
        return Words.join(words)
    }

    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "st", "jr", "sr", "vs", "etc", "inc", "ltd", "co",
        "a.m", "p.m", "e.g", "i.e", "approx", "dept", "est", "fig", "mt", "u.s",
    ]

    /// A sentence end, not the period of "Mr." or "p.m." or an initial.
    private static func endsSentence(_ word: Word) -> Bool {
        guard word.endsSentence else { return false }
        if word.trailing.first == ".", abbreviations.contains(word.lower) { return false }
        if word.trailing.first == ".", word.core.count == 1, word.isCapitalized { return false }
        return true
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
                } else if previous.trailing.hasSuffix(","), !discourseMarkers.contains(previous.lower),
                          !opensCorrection(input, after: index), !isNumberCorrectionPause(input, at: index) {
                    previous.trailing.removeLast()
                }
                out.append(previous)
            }
        }
        return out
    }

    /// "…ask if you, um, let me rephrase that": the comma before the filler is the pause before a
    /// correction, and without it the correction reads as part of the sentence.
    private static let correctionOpeners: Set<String> = [
        "let", "sorry", "actually", "no", "wait", "scratch", "scrap", "strike", "correction", "rather",
        "make", "my", "i", "or", "oops",
    ]

    private static func opensCorrection(_ words: [Word], after index: Int) -> Bool {
        guard let next = words[(index + 1)...].first(where: { !fillers.contains($0.lower) }) else { return false }
        return correctionOpeners.contains(next.lower)
    }

    /// A filler used as the pause in a correction of a number: "five nights, er, four". Removing
    /// it would leave "five nights four", so the comma stays and the LLM is asked to resolve it.
    static func isNumberCorrectionPause(_ words: [Word], at index: Int) -> Bool {
        guard index > 0, fillers.contains(words[index].lower),
              words[index - 1].trailing.hasSuffix(",") || words[index].trailing.hasPrefix(","),
              let next = words[(index + 1)...].first(where: { !fillers.contains($0.lower) }), isNumber(next)
        else { return false }
        return words[max(0, index - 4)..<index].contains(where: isNumber)
    }

    private static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
        "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
        "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred",
        "thousand", "million", "half",
    ]

    private static func isNumber(_ word: Word) -> Bool {
        if word.core.first?.isNumber == true { return true }
        let parts = word.lower.split(separator: "-")
        return !parts.isEmpty && parts.allSatisfy { numberWords.contains(String($0)) }
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
        (.correction, #"\b(scratch that|scrap that|strike that|delete that|cancel that|undo that|take that back|never ?mind|no,? wait|wait,? no|i mean|i meant|actually|sorry|correction|better yet|make that|change that|on second thought|i misspoke|my bad|let me correct|let me rephrase|rephrase that|start over|start again|scratch|scrap)\b"#),
        // Narrower forms of words that are usually ordinary text: "…, or rather Wednesday",
        // "…, and make it 4", "…Kestrel instead.", "the parser, no, the lexer", "forty, let's say fifty".
        (.correction, #"(?:\bor|[,;])\s+rather\b|[,.;!?]\s+(?:and\s+)?make it\b|\binstead(?=\s*[.,;!?]|\s*$)|[,;]\s+no,\s|[,;]\s+let'?s say\b"#),
        // A false start that breaks off after "the" or a possessive: "Can we push the, I'd like…".
        (.correction, #"\b(?:the|my|our|your|their),\s"#),
        // An addition after a pause: "…. Oh, and also drinks", "…. And add oranges", "…. Oh, and a whiteboard".
        (.correction, #"[,.;!?]\s+(?:(?:oh|ok(?:ay)?|wait|actually|so)[,.]?\s+)*(?:and also|and add|add)\b|[.!?]\s+oh,?\s+and\b"#),
        // A short corrective fragment that ends the dictation: "The bug is in the parser. No, the lexer."
        (.correction, #"[.!?]\s+no,\s+(?:\S+\s+){0,3}\S+\s*$"#),
        (.correction, #"(?:^|[,.;!?]\s*)(?:oh,? )?wait[,.!]"#),
        (.list, #"\b(first(ly)?\b.*\bsecond(ly)?|number one\b.*\bnumber two|bullet( point)?s?|numbered list|bulleted list|to-?do list|the following|next item|item one)\b"#),
        (.list, #"(^|\s)(one|1)[,.:)]\s.*\s(two|2)[,.:)]\s"#),
        (.filler, #"\byou know\b|\bsort of\b|\b(was|were|is|it's|and|just|so|but|um|uh),? like,? \b|, like,"#),
        (.formatting, #"\b(new ?line|new paragraph|next line|open quote|close quote|end quote|open paren(thesis)?|close paren(thesis)?|all caps|semicolon|exclamation (point|mark)|question mark|em dash)\b"#),
    ].map { cue, pattern in (cue, try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) }

    static func detectCues(_ text: String) -> Set<CleanupCue> {
        let range = NSRange(text.startIndex..., in: text)
        var cues: Set<CleanupCue> = []
        for (cue, regex) in cuePatterns {
            // A revision needs something before it to revise, so a cue that opens the dictation
            // ("Never mind the noise, the call went fine", "Actually, it went well") doesn't count.
            let counts = regex.matches(in: text, range: range).contains { match in
                cue != .correction || hasWords(before: match.range, in: text)
            }
            if counts { cues.insert(cue) }
        }
        if retractsSomethingSaid(text) { cues.insert(.correction) }
        return cues
    }

    // A removal, narrowing or swap after a pause: "…, skip the butter", "…. Not Jordan.", "…, just
    // marketing", "…. Take the phone case off.", "…. Forget what I said about the engineers.",
    // "…. Swap mobile for cost." It only counts when it names something already said, so "I want
    // pizza, not wings", "skip the intro" at the start and "we decided to drop it" stay on the
    // fast path. Group 1 is the first word of what it names.
    private static let retractions: [NSRegularExpression] = [
        #"(?:drop|skip|forget|ignore|disregard|remove|delete|cut|lose|strike|cross off|cross out|nix|take out|take off|leave out|leave off|minus|without|except|exclude|not|just|only)\s+(?:(?:the|a|an|my|our|your)\s+)?([\p{L}\p{N}][\p{L}\p{N}'-]*)"#,
        #"(?:take|leave|cross|strike|knock)\s+(?:(?:the|a|an|my|our|your|that)\s+)?([\p{L}\p{N}][\p{L}\p{N}'-]*)(?:\s+[\p{L}\p{N}'-]+){0,2}\s+(?:off|out)\b"#,
        #"(?:forget|ignore|disregard|scratch|never mind)\s+(?:what|everything|the part|the bit)\s+I\s+said\s+about\s+(?:(?:the|a|an|my|our|your)\s+)?([\p{L}\p{N}][\p{L}\p{N}'-]*)"#,
        #"(?:swap|switch|replace|change|trade)\s+(?:out\s+)?(?:(?:the|a|an|my|our|your)\s+)?([\p{L}\p{N}][\p{L}\p{N}'-]*)(?:\s+[\p{L}\p{N}'-]+){0,2}\s+(?:for|with|to)\b"#,
    ].map { verb in
        try! NSRegularExpression(
            pattern: #"[,.;!?]\s+(?:(?:oh|ok(?:ay)?|wait|actually|and|so|no|hmm|but|also|um|uh)[,.]?\s+)*"# + verb,
            options: [.caseInsensitive]
        )
    }

    /// Words that point back without repeating what they point at ("delete the last one", "forget that").
    private static let pointers: Set<String> = [
        "last", "first", "second", "third", "other", "one", "two", "both", "latter", "former", "rest",
        "it", "that", "this", "those", "these", "them",
    ]

    static func retractsSomethingSaid(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return retractions.flatMap { $0.matches(in: text, range: range) }.contains { match in
            guard let whole = Range(match.range, in: text), let object = Range(match.range(at: 1), in: text) else { return false }
            let word = stem(text[object])
            if pointers.contains(word) { return true }
            return Words.split(String(text[..<whole.lowerBound])).contains { stem($0.core) == word }
        }
    }

    /// Lowercased, without a plural "s", so "eggs" matches "egg".
    private static func stem<S: StringProtocol>(_ word: S) -> String {
        var lowered = word.lowercased()
        if lowered.count > 3, lowered.hasSuffix("s") { lowered.removeLast() }
        return lowered
    }

    private static func hasWords(before range: NSRange, in text: String) -> Bool {
        guard let lower = Range(range, in: text)?.lowerBound else { return false }
        return text[..<lower].contains { $0.isLetter || $0.isNumber }
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
            // "that" has to end the clause, so "scrap that plan" is left alone.
            let isCommand = scratchVerbs.contains(words[index].lower) && words[index + 1].lower == "that"
                && words[index].leading.isEmpty && (!words[index + 1].trailing.isEmpty || index + 2 == words.count)
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
