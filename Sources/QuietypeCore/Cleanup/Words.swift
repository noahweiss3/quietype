import Foundation

/// A transcript word split into the punctuation around it, so rules can drop or merge
/// words without mangling commas and sentence endings.
struct Word: Equatable {
    var leading: String
    var core: String
    var trailing: String

    var lower: String { core.lowercased() }
    var text: String { leading + core + trailing }

    /// True when the word ends a sentence ("done." / "really?!").
    var endsSentence: Bool { trailing.contains(where: { ".!?".contains($0) }) }

    var isCapitalized: Bool { core.first?.isUppercase ?? false }

    init(leading: String = "", core: String, trailing: String = "") {
        self.leading = leading
        self.core = core
        self.trailing = trailing
    }

    init(_ token: Substring) {
        // Apostrophes and hyphens inside a word belong to the core ("don't", "follow-up"),
        // but quotes and brackets at the edges don't.
        let edge: (Character) -> Bool = { c in !(c.isLetter || c.isNumber) }
        let start = token.firstIndex(where: { !edge($0) }) ?? token.endIndex
        let end = token.lastIndex(where: { !edge($0) }).map { token.index(after: $0) } ?? start
        leading = String(token[token.startIndex..<start])
        core = String(token[start..<max(start, end)])
        trailing = String(token[max(start, end)..<token.endIndex])
    }

    /// Uppercases the first letter unless the word has deliberate casing ("iPhone", "eBay").
    mutating func capitalize() {
        guard let first = core.first, first.isLowercase,
            !core.dropFirst().contains(where: { $0.isUppercase })
        else { return }
        core = first.uppercased() + core.dropFirst()
    }
}

enum Words {
    static func split(_ text: String) -> [Word] {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(Word.init)
    }

    static func join(_ words: [Word]) -> String {
        words.map(\.text).joined(separator: " ")
    }
}

extension String {
    /// Collapses runs of spaces/tabs and trims, but keeps newlines.
    var collapsingSpaces: String {
        let lines = split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
