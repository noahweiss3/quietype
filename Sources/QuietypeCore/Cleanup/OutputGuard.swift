import Foundation

/// Catches the LLM going off-script: answering the dictation instead of cleaning it,
/// adding commentary, or inventing content. A rejected answer falls back to the rules output.
public enum OutputGuard {
    public enum Verdict: Equatable, Sendable {
        case accepted(String)
        case rejected(reason: String)
    }

    /// Strips wrappers small models like to add: think blocks, tags, quotes, "Here is ...:" lines.
    public static func sanitize(_ output: String) -> String {
        var text = output
        if let range = text.range(of: "</think>") { text = String(text[range.upperBound...]) }
        for tag in ["<dictation>", "</dictation>"] { text = text.replacingOccurrences(of: tag, with: "") }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let firstLine = text.split(separator: "\n", maxSplits: 1).first,
            firstLine.count < 80, firstLine.hasSuffix(":"),
            firstLine.lowercased().hasPrefix("here is") || firstLine.lowercased().hasPrefix("here's")
                || firstLine.lowercased().hasPrefix("cleaned")
        {
            text = String(text.dropFirst(firstLine.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for (open, close) in [("\"", "\""), ("“", "”"), ("```", "```"), ("'", "'")] {
            if text.count > open.count + close.count, text.hasPrefix(open), text.hasSuffix(close) {
                let inner = text.dropFirst(open.count).dropLast(close.count)
                if !inner.contains(open) { text = String(inner).trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
        // Markdown-style hard breaks ("line  \n") are noise outside a markdown renderer.
        text = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
        return renumberingLists(text)
    }

    /// The model keeps the speaker's numbering, so an item taken back leaves a gap ("first eggs,
    /// second milk, third bread, scratch the bread, fourth coffee" → 1, 2, 4). This renumbers a
    /// list that starts at 1 so it reads 1…n.
    static func renumberingLists(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var start = 0
        while start < lines.count {
            var numbers: [Int] = []
            while start + numbers.count < lines.count, let number = listNumber(lines[start + numbers.count]),
                number > (numbers.last ?? 0)
            {
                numbers.append(number)
            }
            if numbers.first == 1, numbers != Array(1...numbers.count) {
                for offset in numbers.indices {
                    let line = lines[start + offset]
                    lines[start + offset] = String(offset + 1) + String(line.drop { $0.isNumber })
                }
            }
            start += max(numbers.count, 1)
        }
        return lines.joined(separator: "\n")
    }

    private static func listNumber(_ line: String) -> Int? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return Int(digits)
    }

    public static func check(input: String, output rawOutput: String, cues: Set<CleanupCue>) -> Verdict {
        let output = sanitize(rawOutput)
        let inputWords = comparableWords(input)
        let outputWords = comparableWords(output)
        // "bullet point", "new line" and spoken punctuation become markup, not words.
        let spokenWords = comparableWords(withoutSpokenFormatting(input))

        if outputWords.isEmpty {
            // Only right when the speaker cancelled everything they said. A replacement ("two, no
            // wait, three") or a partial retraction also carries a correction cue, and emptying
            // one of those would lose the whole dictation.
            return inputWords.isEmpty || (cues.contains(.correction) && Rules.retractsEverything(input))
                ? .accepted(output) : .rejected(reason: "empty output")
        }

        // Without a correction nothing should disappear but fillers. Losing most of the text
        // means the model obeyed the dictation ("...reply with the word banana" → "banana").
        // A correction can legitimately drop a lot ("... Scratch that."), but not nearly everything.
        let droppedTooMuch =
            cues.contains(.correction)
            ? outputWords.count * 4 <= spokenWords.count
            : outputWords.count * 2 < spokenWords.count
        if droppedTooMuch, !isRestartedTail(output: outputWords, input: input) {
            return .rejected(reason: "dropped too much (\(outputWords.count) of \(spokenWords.count) words)")
        }

        if outputWords.count > inputWords.count + max(4, inputWords.count / 5) {
            return .rejected(reason: "output longer than input (\(outputWords.count) vs \(inputWords.count) words)")
        }

        let known = Set(inputWords)
        let novel = outputWords.filter { !known.contains($0) }
        let allowedNovel = max(2, outputWords.count / 5)
        if novel.count > allowedNovel {
            return .rejected(reason: "too many new words: \(novel.prefix(6).joined(separator: ", "))")
        }

        // A changed number or a flipped "not" is one word, well within the novelty allowance, yet
        // it reverses what the speaker meant.
        if let number = inventedNumbers(input: input, output: output).first {
            return .rejected(reason: "number not in the dictation: \(number)")
        }
        let saidNegations = negations(in: input)
        let keptNegations = negations(in: output)
        // Taking something back only ever removes words, so a new "not" is never a cleanup.
        if keptNegations > saidNegations {
            return .rejected(reason: "added a negation")
        }
        // A retraction the cues missed ("…, you won't need the putty knife, …") drops its "won't"
        // along with what it names. Losing the negation and nothing else is a flipped meaning.
        if !cues.contains(.correction), keptNegations < saidNegations,
            spokenWords.count - outputWords.count <= saidNegations - keptNegations
        {
            return .rejected(reason: "dropped a negation")
        }
        return .accepted(output)
    }

    // The same command lists the rules and the cleanup prompt use, so a command the prompt turns
    // into markup is never counted as a dropped word.
    private static let spokenFormatting = try! NSRegularExpression(
        pattern: Rules.commandPattern(Rules.layoutCommands + Rules.punctuationCommands + Rules.listCommands),
        options: [.caseInsensitive]
    )

    static func withoutSpokenFormatting(_ text: String) -> String {
        spokenFormatting.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
    }

    /// True when the output only uses words spoken after the last "start over", which is what a
    /// correct start-over looks like even though it drops most of the dictation.
    static func isRestartedTail(output: [String], input: String) -> Bool {
        let lowered = input.lowercased()
        let restarts = Rules.startOverPhrases.compactMap { lowered.range(of: $0, options: .backwards) }
        guard let restart = restarts.max(by: { $0.upperBound < $1.upperBound }) else { return false }
        let tail = Set(comparableWords(String(lowered[restart.upperBound...])))
        return !tail.isEmpty && output.allSatisfy(tail.contains)
    }

    /// Lowercased words with spoken numbers mapped to digits, so "four" in the input matches "4".
    static func comparableWords(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
            .map { word in
                let w = String(word).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                return numberWords[w] ?? w
            }
            .filter { !$0.isEmpty && !ignorable.contains($0) }
    }

    private static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
        "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12",
        "first": "1", "second": "2", "third": "3", "fourth": "4", "fifth": "5", "sixth": "6",
        "seventh": "7", "eighth": "8", "ninth": "9", "tenth": "10",
    ]

    // MARK: Numbers and negation

    /// Numbers written as digits in the output that the speaker never said. A list's own numbering
    /// doesn't count, and neither does a run of spoken digits written as one number ("five five
    /// five" as 555). Nothing is reported when the dictation has number words that combine with
    /// others ("four twenty-five" is 425, "three fifty" is 350), which can be written too many ways
    /// to trace back word by word.
    static func inventedNumbers(input: String, output: String) -> [String] {
        let spoken = tokens(input)
        guard !spoken.contains(where: compoundNumberWords.contains) else { return [] }
        let said = numbers(in: spoken, countingWords: true)
        var explained: Set<String> = ["0"] // the padding of "7:00"
        for start in said.indices {
            for end in start..<min(said.count, start + 12) { explained.insert(said[start...end].joined()) }
        }
        let body = output.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: #"^\s*\d+[.)]\s"#, with: "", options: .regularExpression) }
            .joined(separator: "\n")
        return numbers(in: tokens(body), countingWords: false).filter { !explained.contains($0) }
    }

    private static let numberToken = try! NSRegularExpression(pattern: #"\d+|\p{L}+"#)

    /// Lowercased runs of digits or letters, with thousands separators dropped so "4,250" is one run.
    private static func tokens(_ text: String) -> [String] {
        let joined = text.replacingOccurrences(of: #"(?<=\d),(?=\d{3}(?!\d))"#, with: "", options: .regularExpression)
        let range = NSRange(joined.startIndex..., in: joined)
        return numberToken.matches(in: joined, range: range).compactMap { match in
            Range(match.range, in: joined).map { joined[$0].lowercased() }
        }
    }

    /// The numbers among `tokens`, in order and without leading zeros ("05" is "5"). With
    /// `countingWords`, small number words count as their digits too.
    private static func numbers(in tokens: [String], countingWords: Bool) -> [String] {
        tokens.compactMap { token in
            if countingWords, let digit = numberWords[token] { return digit }
            guard token.first?.isNumber == true else { return nil }
            let trimmed = token.drop { $0 == "0" }
            return trimmed.isEmpty ? "0" : String(trimmed)
        }
    }

    private static let compoundNumberWords: Set<String> = [
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
        "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "hundreds", "thousand", "thousands", "million", "millions", "billion", "billions",
        "dozen", "dozens", "half", "halves", "quarter", "quarters",
        "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth",
        "eighteenth", "nineteenth", "twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth",
        "seventieth", "eightieth", "ninetieth", "hundredth", "thousandth",
    ]

    /// How often the text says "not", "never" or a "-n't" contraction, written with or without
    /// the apostrophe. "Never mind" takes something back rather than negating it.
    static func negations(in text: String) -> Int {
        let lowered = text.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"\bnever ?mind\b"#, with: " ", options: .regularExpression)
        return lowered.split { !($0.isLetter || $0 == "'") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { $0.hasSuffix("n't") || negationWords.contains($0.replacingOccurrences(of: "'", with: "")) }
            .count
    }

    private static let negationWords: Set<String> = [
        "not", "never", "cannot", "nor", "dont", "doesnt", "didnt", "isnt", "arent", "wasnt", "werent",
        "cant", "couldnt", "shouldnt", "wouldnt", "wont", "hasnt", "havent", "hadnt", "aint", "mustnt",
        "neednt",
    ]

    // Words the cleanup may legitimately introduce: list glue, contractions, articles.
    private static let ignorable: Set<String> = [
        "a", "an", "the", "and", "or", "to", "of", "s", "t", "is", "are", "it", "i", "m", "re", "ll", "ve", "d",
    ]
}
