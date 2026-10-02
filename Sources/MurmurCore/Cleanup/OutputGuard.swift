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
            || firstLine.lowercased().hasPrefix("cleaned") {
            text = String(text.dropFirst(firstLine.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for (open, close) in [("\"", "\""), ("“", "”"), ("```", "```"), ("'", "'")] {
            if text.count > open.count + close.count, text.hasPrefix(open), text.hasSuffix(close) {
                let inner = text.dropFirst(open.count).dropLast(close.count)
                if !inner.contains(open) { text = String(inner).trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
        return text
    }

    public static func check(input: String, output rawOutput: String, cues: Set<CleanupCue>) -> Verdict {
        let output = sanitize(rawOutput)
        let inputWords = comparableWords(input)
        let outputWords = comparableWords(output)

        if outputWords.isEmpty {
            // Only plausible when the speaker cancelled everything they said.
            return cues.contains(.correction) || inputWords.isEmpty
                ? .accepted(output) : .rejected(reason: "empty output")
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
        return .accepted(output)
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

    // Words the cleanup may legitimately introduce: list glue, contractions, articles.
    private static let ignorable: Set<String> = [
        "a", "an", "the", "and", "or", "to", "of", "s", "t", "is", "are", "it", "i", "m", "re", "ll", "ve", "d",
    ]
}
