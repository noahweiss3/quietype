import Foundation

/// A voice shortcut: say the trigger ("my LinkedIn") and the stored text is typed instead.
public struct Snippet: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var trigger: String
    public var text: String

    public init(id: UUID = UUID(), trigger: String, text: String) {
        self.id = id
        self.trigger = trigger
        self.text = text
    }

    /// The trigger reduced to lowercase letters and digits, so "My Linked-In" and "my linkedin"
    /// are the same trigger. Empty when the trigger has nothing to match on.
    public var key: String { Snippets.normalize(trigger) }
}

/// Expands snippet triggers in finished dictation text.
///
/// Matching ignores case, punctuation and the spacing between words, because the transcriber
/// may hear "my LinkedIn" as "my linked in" or "My LinkedIn." A trigger only matches whole
/// words, so "army LinkedIn" doesn't contain "my LinkedIn".
///
/// Expansion runs after cleanup, so corrections apply first ("my LinkedIn, no wait, my GitHub"
/// only expands GitHub), and the stored text goes in exactly as written: the LLM and the
/// dictionary never see it.
public struct Snippets: Codable, Equatable, Sendable {
    public var items: [Snippet]

    public init(_ items: [Snippet] = []) {
        self.items = items
    }

    public var isEmpty: Bool { items.allSatisfy { $0.key.isEmpty } }

    public struct Expansion: Equatable, Sendable {
        public var text: String
        /// Triggers that were expanded, in order of appearance.
        public var used: [String]
    }

    public func expand(_ text: String) -> Expansion {
        // Longest trigger first, so "my work email" wins over "my work".
        let candidates = items.filter { !$0.key.isEmpty }.sorted { $0.key.count > $1.key.count }
        guard !candidates.isEmpty else { return Expansion(text: text, used: []) }

        let words = Self.words(in: text)
        var matches: [(range: Range<String.Index>, snippet: Snippet)] = []
        var claimed = Set<Int>()

        for snippet in candidates {
            let key = snippet.key
            var start = 0
            while start < words.count {
                guard !claimed.contains(start), let end = Self.match(key, in: words, from: start, skipping: claimed) else {
                    start += 1
                    continue
                }
                matches.append((words[start].range.lowerBound..<words[end].range.upperBound, snippet))
                claimed.formUnion(start...end)
                start = end + 1
            }
        }
        guard !matches.isEmpty else { return Expansion(text: text, used: []) }
        matches.sort { $0.range.lowerBound < $1.range.lowerBound }

        // A dictation that is only the trigger ("My email signature.") becomes exactly the
        // stored text, without the period the transcriber or cleanup put after it.
        if matches.count == 1, claimed.count == words.count {
            return Expansion(text: matches[0].snippet.text, used: [matches[0].snippet.trigger])
        }

        var result = ""
        var cursor = text.startIndex
        for match in matches {
            result += text[cursor..<match.range.lowerBound]
            result += match.snippet.text
            cursor = match.range.upperBound
        }
        // "…thanks. My email signature." shouldn't leave a period under a signature block.
        let rest = text[cursor...]
        let endsWithBlock = matches.last!.snippet.text.contains("\n") && rest.allSatisfy { ".!? ".contains($0) }
        if !endsWithBlock { result += rest }
        return Expansion(text: result, used: matches.map(\.snippet.trigger))
    }

    // MARK: Matching

    struct WordSpan {
        var key: String
        var range: Range<String.Index>
    }

    /// Words as runs of letters, digits and inner apostrophes, with their position in `text`.
    static func words(in text: String) -> [WordSpan] {
        var spans: [WordSpan] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard isWordCharacter(text[index]) else {
                index = text.index(after: index)
                continue
            }
            let start = index
            var end = index
            while index < text.endIndex {
                let character = text[index]
                if isWordCharacter(character) {
                    index = text.index(after: index)
                    end = index
                } else if character == "'" || character == "’",
                          text.index(after: index) < text.endIndex, isWordCharacter(text[text.index(after: index)]) {
                    index = text.index(after: index)
                } else {
                    break
                }
            }
            spans.append(WordSpan(key: normalize(String(text[start..<end])), range: start..<end))
        }
        return spans
    }

    /// The index of the last word when the words starting at `start` spell out `key` exactly.
    static func match(_ key: String, in words: [WordSpan], from start: Int, skipping claimed: Set<Int>) -> Int? {
        var spelled = ""
        var index = start
        while index < words.count, !claimed.contains(index) {
            spelled += words[index].key
            if spelled == key { return index }
            guard spelled.count < key.count, key.hasPrefix(spelled) else { return nil }
            index += 1
        }
        return nil
    }

    static func normalize(_ text: String) -> String {
        String(text.lowercased().filter(isWordCharacter))
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
