import Foundation

public enum CleanupMode: String, Codable, Sendable, CaseIterable {
    /// Rules only: fillers, stutters, "start over", basic "scratch that". No LLM.
    case rulesOnly
    /// Rules, plus the LLM when the transcript has corrections, lists or formatting commands.
    case smart
    /// Rules, then the LLM on every dictation.
    case always
}

/// Rewrites a dictation with an LLM. Implemented on macOS by the llama.cpp runner.
public protocol TextCleaner: Sendable {
    func clean(_ dictation: String, style: WritingStyle, vocabulary: [String]) async throws -> String
}

public struct DictationContext: Sendable {
    public var style: WritingStyle
    public var mode: CleanupMode
    public var dictionary: PersonalDictionary
    public var snippets: Snippets
    public var appendTrailingSpace: Bool

    public init(
        style: WritingStyle = .standard, mode: CleanupMode = .smart,
        dictionary: PersonalDictionary = PersonalDictionary(),
        snippets: Snippets = Snippets(), appendTrailingSpace: Bool = true
    ) {
        self.style = style
        self.mode = mode
        self.dictionary = dictionary
        self.snippets = snippets
        self.appendTrailingSpace = appendTrailingSpace
    }
}

public struct ProcessedDictation: Codable, Equatable, Sendable {
    public enum Path: String, Codable, Sendable {
        case rules
        case llm
        /// The LLM ran but its answer failed the guard or errored.
        case llmRejected
    }

    public var raw: String
    public var text: String
    public var path: Path
    public var note: String?
    public var rulesSeconds: Double
    public var llmSeconds: Double?
    /// Snippet triggers that were expanded.
    public var snippets: [String]? = nil
}

/// Everything between the transcript and the text that gets pasted.
public struct DictationProcessor: Sendable {
    public var cleaner: TextCleaner?

    public init(cleaner: TextCleaner?) {
        self.cleaner = cleaner
    }

    public func process(_ raw: String, context: DictationContext) async -> ProcessedDictation {
        let started = Date()
        let rules = Rules.apply(raw)
        let rulesSeconds = Date().timeIntervalSince(started)

        var text = rules.text
        var path = ProcessedDictation.Path.rules
        var note: String?
        var llmSeconds: Double?

        let wantsLLM = context.mode == .always || (context.mode == .smart && rules.needsLLM)
        if wantsLLM, let cleaner, !rules.text.isEmpty {
            let llmStarted = Date()
            do {
                let vocabulary = Self.cleanupVocabulary(for: rules.text, context: context)
                let output = try await cleaner.clean(rules.text, style: context.style, vocabulary: vocabulary)
                switch OutputGuard.check(input: rules.text, output: output, cues: rules.cues) {
                case let .accepted(cleaned):
                    text = cleaned
                    path = .llm
                case let .rejected(reason):
                    path = .llmRejected
                    note = "\(reason): \(output.prefix(200))"
                }
            } catch {
                path = .llmRejected
                note = "cleanup failed: \(error)"
            }
            llmSeconds = Date().timeIntervalSince(llmStarted)
        }

        if path != .llm { text = Rules.applyFallbackCorrections(text) }
        text = context.dictionary.apply(to: text)
        text = Self.finalize(text, style: context.style)
        // Last, so neither the LLM nor the dictionary touches the stored text, and the code-style
        // period is decided on what was said rather than on the dots inside a URL.
        let expansion = context.snippets.expand(text)
        text = expansion.text
        if context.appendTrailingSpace {
            text = Self.appendingTrailingSpace(to: text, style: context.style, expandedSnippet: !expansion.used.isEmpty)
        }

        return ProcessedDictation(
            raw: raw, text: text, path: path, note: note, rulesSeconds: rulesSeconds, llmSeconds: llmSeconds,
            snippets: expansion.used.isEmpty ? nil : expansion.used
        )
    }

    /// What the LLM is told to spell exactly: the dictionary's terms plus the snippet triggers said
    /// in this dictation, so a trigger isn't reworded ("first my GitHub" → "1. GitHub") before it
    /// can expand. Only triggers go to the LLM, never the stored text.
    public static func cleanupVocabulary(for text: String, context: DictationContext) -> [String] {
        context.dictionary.terms + context.snippets.expand(text).used
    }

    /// Trims, and drops the period after a single phrase in a terminal or editor.
    static func finalize(_ text: String, style: WritingStyle) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if style == .code, !result.contains("\n"), result.hasSuffix("."), !result.dropLast().contains(".") {
            result.removeLast()
        }
        return result
    }

    /// Adds a space after a finished sentence so back-to-back dictations don't run together. An
    /// expanded snippet counts as finished: it may have swallowed the period ("My calendly link."
    /// is just the URL), and the next dictation would otherwise run into it.
    static func appendingTrailingSpace(to text: String, style: WritingStyle, expandedSnippet: Bool) -> String {
        guard style != .code, !text.isEmpty, !text.contains("\n"), let last = text.last else { return text }
        return expandedSnippet || ".!?,;:".contains(last) ? text + " " : text
    }
}
