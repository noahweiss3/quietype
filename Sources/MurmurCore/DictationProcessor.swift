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

    public init(style: WritingStyle = .standard, mode: CleanupMode = .smart, dictionary: PersonalDictionary = PersonalDictionary(), snippets: Snippets = Snippets(), appendTrailingSpace: Bool = true) {
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
                let output = try await cleaner.clean(rules.text, style: context.style, vocabulary: context.dictionary.terms)
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
        // Last, so neither the LLM nor the dictionary touches the stored text.
        let expansion = context.snippets.expand(text)
        text = Self.finalize(expansion.text, style: context.style, appendTrailingSpace: context.appendTrailingSpace)

        return ProcessedDictation(
            raw: raw, text: text, path: path, note: note, rulesSeconds: rulesSeconds, llmSeconds: llmSeconds,
            snippets: expansion.used.isEmpty ? nil : expansion.used
        )
    }

    /// Adds a trailing space after a finished sentence so back-to-back dictations don't run together.
    static func finalize(_ text: String, style: WritingStyle, appendTrailingSpace: Bool) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if style == .code, !result.contains("\n"), result.hasSuffix("."), !result.dropLast().contains(".") {
            result.removeLast() // a single phrase in a terminal or editor shouldn't end with a period
        }
        if appendTrailingSpace, !result.isEmpty, style != .code, !result.contains("\n"),
           let last = result.last, ".!?,;:".contains(last) {
            result += " "
        }
        return result
    }
}
