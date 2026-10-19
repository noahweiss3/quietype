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

    public var isEmpty: Bool { active.isEmpty }

    /// Snippets with something to match and something to type; a half-filled row does nothing.
    var active: [Snippet] {
        items.filter { !$0.key.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public struct Expansion: Equatable, Sendable {
        public var text: String
        /// Triggers that were expanded, in order of appearance.
        public var used: [String]
    }

    public func expand(_ text: String) -> Expansion {
        // Longest trigger first, so "my work email" wins over "my work"; for the same trigger, the
        // snippet listed first.
        let candidates = active.enumerated()
            .sorted { ($0.element.key.count, $1.offset) > ($1.element.key.count, $0.offset) }
            .map(\.element)
        guard !candidates.isEmpty else { return Expansion(text: text, used: []) }

        let words = Self.words(in: text)
        var matches: [(range: Range<String.Index>, snippet: Snippet)] = []
        var claimed = Set<Int>()

        for snippet in candidates {
            let key = snippet.key
            var start = 0
            while start < words.count {
                guard !claimed.contains(start), let end = Self.match(key, in: words, from: start, skipping: claimed, text: text) else {
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
            // Stored text that ends a sentence ("…after 2pm.") doesn't need the transcript's period too.
            if let last = match.snippet.text.trimmingCharacters(in: .whitespacesAndNewlines).last, ".!?…".contains(last) {
                while cursor < text.endIndex, ".!?".contains(text[cursor]) { cursor = text.index(after: cursor) }
            }
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
    /// The words may be separated only by spaces or hyphens ("my linked-in"), so a trigger never
    /// spans a comma or sentence break ("Oh my, LinkedIn is down"), and it can't be the start or
    /// end of a longer token such as "linkedin.com" or "my-linkedin-page".
    static func match(_ key: String, in words: [WordSpan], from start: Int, skipping claimed: Set<Int>, text: String) -> Int? {
        guard !isJoined(before: words[start].range.lowerBound, in: text) else { return nil }
        var spelled = ""
        var index = start
        while index < words.count, !claimed.contains(index) {
            if index > start {
                let gap = text[words[index - 1].range.upperBound..<words[index].range.lowerBound]
                guard gap.allSatisfy({ $0 == " " || $0 == "-" }) else { return nil }
            }
            spelled += words[index].key
            if spelled == key { return isJoined(after: words[index].range.upperBound, in: text) ? nil : index }
            guard spelled.count < key.count, key.hasPrefix(spelled) else { return nil }
            index += 1
        }
        return nil
    }

    private static let joiners: Set<Character> = ["-", ".", "@", "/", "_"]

    /// True when the token goes on past `index` through a joiner, as in "linkedin.com".
    private static func isJoined(after index: String.Index, in text: String) -> Bool {
        guard index < text.endIndex, joiners.contains(text[index]) else { return false }
        let next = text.index(after: index)
        return next < text.endIndex && isWordCharacter(text[next])
    }

    /// True when the token started before `index`, as in "www.mylinkedin".
    private static func isJoined(before index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return false }
        let previous = text.index(before: index)
        guard joiners.contains(text[previous]), previous > text.startIndex else { return false }
        return isWordCharacter(text[text.index(before: previous)])
    }

    static func normalize(_ text: String) -> String {
        String(text.lowercased().filter(isWordCharacter))
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
