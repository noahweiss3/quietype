import Foundation

/// Words the transcriber tends to get wrong: names, jargon, product names.
///
/// Edited as plain text, one entry per line:
///
///     Kubernetes
///     cooper netties -> Kubernetes
///     # comments are ignored
///
/// A bare term is passed to the LLM as preferred spelling and fixes casing ("github" → "GitHub").
/// "a -> b" replaces the spoken form wherever it appears as whole words.
public struct PersonalDictionary: Equatable, Sendable {
    public struct Replacement: Equatable, Sendable {
        public var from: String
        public var to: String
    }

    public var terms: [String]
    public var replacements: [Replacement]

    public init(terms: [String] = [], replacements: [Replacement] = []) {
        self.terms = terms
        self.replacements = replacements
    }

    public init(parsing text: String) {
        var terms: [String] = []
        var replacements: [Replacement] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if let arrow = line.range(of: "->") {
                let from = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                let to = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                if !from.isEmpty, !to.isEmpty {
                    replacements.append(Replacement(from: from, to: to))
                    terms.append(to)
                }
            } else {
                terms.append(line)
            }
        }
        var seen = Set<String>()
        self.init(terms: terms.filter { seen.insert($0.lowercased()).inserted }, replacements: replacements)
    }

    public func apply(to text: String) -> String {
        var result = text
        // Longest first so "new york times" wins over "new york".
        let rules = replacements.map { ($0.from, $0.to) } + terms.map { ($0, $0) }
        for (from, to) in rules.sorted(by: { $0.0.count > $1.0.count }) {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: from) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: to)
            )
        }
        return result
    }
}
