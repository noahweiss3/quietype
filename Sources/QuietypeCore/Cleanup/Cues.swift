import Foundation

// Cue detection: deciding whether a transcript needs the LLM at all. The phrases that mark a
// correction, a list or a formatting command live here, so this is the file to change when a new
// way of saying one of them should reach the LLM.
extension Rules {
    private static let cuePatterns: [(CleanupCue, NSRegularExpression)] = [
        (
            .correction,
            #"\b(scratch that|scrap that|strike that|delete that|cancel that|undo that|take that back|"#
                + #"never ?mind|no,? wait|wait,? no|i mean|i meant|actually|sorry|correction|better yet|make that|"#
                + #"change that|on second thought|i misspoke|my bad|let me correct|let me rephrase|rephrase that|"#
                + #"start over|start again|scratch|scrap)\b"#
        ),
        // Narrower forms of words that are usually ordinary text: "…, or rather Wednesday",
        // "…, and make it 4", "…Kestrel instead.", "the parser, no, the lexer", "forty, let's say fifty".
        (
            .correction,
            #"(?:\bor|[,;])\s+rather\b|[,.;!?]\s+(?:and\s+)?make it\b|\binstead(?=\s*[.,;!?]|\s*$)|[,;]\s+no,\s|[,;]\s+let'?s say\b"#
        ),
        // A false start that breaks off after "the" or a possessive: "Can we push the, I'd like…".
        (.correction, #"\b(?:the|my|our|your|their),\s"#),
        // An addition after a pause: "…. Oh, and also drinks", "…. And add oranges", "…. Oh, and a whiteboard".
        (
            .correction,
            #"[,.;!?]\s+(?:(?:oh|ok(?:ay)?|wait|actually|so)[,.]?\s+)*(?:and also|and add|add)\b|[.!?]\s+oh,?\s+and\b"#
        ),
        // A short corrective fragment that ends the dictation: "The bug is in the parser. No, the lexer."
        (.correction, #"[.!?]\s+no,\s+(?:\S+\s+){0,3}\S+\s*$"#),
        (.correction, #"(?:^|[,.;!?]\s*)(?:oh,? )?wait[,.!]"#),
        (
            .list,
            #"\b(first(ly)?\b.*\bsecond(ly)?|number one\b.*\bnumber two|bullet( point)?s?|numbered list|"#
                + #"bulleted list|to-?do list|the following|next item|item one)\b"#
        ),
        (.list, #"(^|\s)(one|1)[,.:)]\s.*\s(two|2)[,.:)]\s"#),
        (.filler, #"\byou know\b|\bsort of\b|\b(was|were|is|it's|and|just|so|but|um|uh),? like,? \b|, like,"#),
        (.formatting, commandPattern(layoutCommands)),
    ].map { cue, pattern in (cue, try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) }

    /// Spoken layout commands the cleanup prompt turns into line breaks or casing.
    static let layoutCommands = ["new line", "newline", "next line", "new paragraph", "all caps"]

    /// Punctuation said by name ("Hello comma Sam"), which the cleanup prompt turns into the symbol.
    static let punctuationCommands = [
        "comma", "period", "full stop", "colon", "semicolon", "question mark", "exclamation point",
        "exclamation mark", "em dash", "open quote", "close quote", "end quote", "open paren",
        "open parenthesis", "close paren", "close parenthesis",
    ]

    /// Spoken list markers the cleanup prompt turns into "- " bullets.
    static let listCommands = ["bullet point", "bullet points"]

    /// A pattern that matches any of `commands` as whole words, however the words inside a
    /// command are spaced.
    static func commandPattern(_ commands: [String]) -> String {
        let names = commands.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: #"\s+"#) }
        return #"\b(?:"# + names.joined(separator: "|") + #")\b"#
    }

    private static let punctuationName = try! NSRegularExpression(
        pattern: commandPattern(punctuationCommands), options: [.caseInsensitive]
    )

    // The names are ordinary nouns too. Said as a command, one follows a word of the sentence;
    // talked about, it follows an article or possessive ("the comma in that sentence", "a question
    // mark over the date"), names a kind ("the Oxford comma") or is part of a compound
    // ("comma-separated", "a period of time", "colon cancer").
    private static let literalBefore: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "my", "your", "our", "his", "its", "their",
        "each", "every", "any", "no", "another", "extra", "missing", "oxford", "serial", "trial", "grace",
        "waiting", "time", "same",
    ]
    private static let literalAfter: Set<String> = ["of", "splice", "splices", "cancer", "key"]

    /// True when the transcript says a punctuation mark as a command rather than talking about it.
    static func dictatesPunctuation(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return punctuationName.matches(in: text, range: range).contains { match in
            guard let name = Range(match.range, in: text) else { return false }
            if text[..<name.lowerBound].last == "-" { return false }
            if let next = text[name.upperBound...].first, "-'’".contains(next) { return false }
            guard let previous = Words.split(String(text[..<name.lowerBound])).last,
                !literalBefore.contains(previous.lower)
            else { return false }
            if let following = Words.split(String(text[name.upperBound...])).first,
                literalAfter.contains(following.lower)
            {
                return false
            }
            return true
        }
    }

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
        if dictatesPunctuation(text) { cues.insert(.formatting) }
        return cues
    }

    // A removal, narrowing or swap after a pause: "…, skip the butter", "…. Not Jordan.", "…, just
    // marketing", "…. Take the phone case off.", "…. Forget what I said about the engineers.",
    // "…. Swap mobile for cost." It only counts when it names something already said, so "I want
    // pizza, not wings", "skip the intro" at the start and "we decided to drop it" stay on the
    // fast path. Group 1 is the first word of what it names.
    private static let retractions: [NSRegularExpression] = [
        #"(?:drop|skip|forget|ignore|disregard|remove|delete|cut|lose|strike|cross off|cross out|nix|take out|take off|"#
            + #"leave out|leave off|minus|without|except|exclude|not|just|only)"#
            + #"\s+(?:(?:the|a|an|my|our|your)\s+)?([\p{L}\p{N}][\p{L}\p{N}'-]*)"#,
        #"(?:take|leave|cross|strike|knock)\s+(?:(?:the|a|an|my|our|your|that)\s+)?([\p{L}\p{N}][\p{L}\p{N}'-]*)"#
            + #"(?:\s+[\p{L}\p{N}'-]+){0,2}\s+(?:off|out)\b"#,
        #"(?:forget|ignore|disregard|scratch|never mind)\s+(?:what|everything|the part|the bit)\s+I\s+said\s+about\s+"#
            + #"(?:(?:the|a|an|my|our|your)\s+)?([\p{L}\p{N}][\p{L}\p{N}'-]*)"#,
        #"(?:swap|switch|replace|change|trade)\s+(?:out\s+)?(?:(?:the|a|an|my|our|your)\s+)?([\p{L}\p{N}][\p{L}\p{N}'-]*)"#
            + #"(?:\s+[\p{L}\p{N}'-]+){0,2}\s+(?:for|with|to)\b"#,
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
            guard let whole = Range(match.range, in: text), let object = Range(match.range(at: 1), in: text) else {
                return false
            }
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
}
