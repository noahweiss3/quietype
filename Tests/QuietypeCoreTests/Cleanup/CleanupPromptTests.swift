import XCTest

@testable import QuietypeCore

final class CleanupPromptTests: XCTestCase {
    /// Stands in for a chat template: any rendering that keeps message contents in order.
    private func render(_ messages: [ChatMessage]) -> String {
        messages.map { "<\($0.role)>\($0.content)</\($0.role)>" }.joined()
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    func testTheContentMarkerAppearsOnlyWhereTheDictationGoes() {
        let rendered = render(
            CleanupPrompt.prefixMessages + [ChatMessage(role: "user", content: CleanupPrompt.contentMarker)])
        XCTAssertEqual(occurrences(of: CleanupPrompt.contentMarker, in: rendered), 1)
        XCTAssertFalse(render(CleanupPrompt.prefixMessages).contains(CleanupPrompt.contentMarker))
    }

    func testThePrefixIsTheSameForEveryDictation() {
        let messages = CleanupPrompt.messages(dictation: "Ship it Friday.", style: .email, vocabulary: ["Kestrel"])
        XCTAssertEqual(Array(messages.dropLast()), CleanupPrompt.prefixMessages)
        XCTAssertEqual(messages.last?.role, "user")
        XCTAssertEqual(
            messages.last?.content,
            "Context: \(WritingStyle.email.promptHint!)\nVocabulary: Kestrel\n<dictation>Ship it Friday.</dictation>")
    }

    func testSplittingAtTheMarkerGivesACacheablePrefixAndAPerDictationSuffix() throws {
        let template = render(
            CleanupPrompt.prefixMessages + [ChatMessage(role: "user", content: CleanupPrompt.contentMarker)])
        let marker = try XCTUnwrap(template.range(of: CleanupPrompt.contentMarker))
        let prefix = String(template[..<marker.lowerBound])
        let suffix = String(template[marker.upperBound...])
        let content = CleanupPrompt.userContent(dictation: "Ship it Friday.", style: .chat, vocabulary: ["Kestrel"])
        XCTAssertEqual(
            prefix + content + suffix,
            render(CleanupPrompt.messages(dictation: "Ship it Friday.", style: .chat, vocabulary: ["Kestrel"])))
    }

    func testStyleAndVocabularyOnlyReachTheFinalMessage() {
        let prefix = render(CleanupPrompt.prefixMessages)
        XCTAssertFalse(prefix.contains("Context:"))
        XCTAssertFalse(prefix.contains("Vocabulary:"))
        XCTAssertEqual(CleanupPrompt.userContent(dictation: "Hi."), "<dictation>Hi.</dictation>")
        for style in WritingStyle.allCases where style != .standard {
            let content = CleanupPrompt.userContent(dictation: "Hi.", style: style)
            XCTAssertTrue(content.hasPrefix("Context: "), "\(style)")
        }
    }

    func testEveryExampleIsAUserAssistantPair() {
        let prefix = CleanupPrompt.prefixMessages
        XCTAssertEqual(prefix.count, 1 + 2 * CleanupPrompt.examples.count)
        XCTAssertEqual(prefix.first?.role, "system")
        for (index, example) in CleanupPrompt.examples.enumerated() {
            XCTAssertEqual(
                prefix[1 + 2 * index], ChatMessage(role: "user", content: "<dictation>\(example.input)</dictation>"))
            XCTAssertEqual(prefix[2 + 2 * index], ChatMessage(role: "assistant", content: example.output))
        }
    }

    func testTheOutputBudgetIsTwiceTheInputPlusRoomForMarkup() {
        XCTAssertEqual(CleanupPrompt.maxOutputTokens(forInputTokens: 0), 48)
        XCTAssertEqual(CleanupPrompt.maxOutputTokens(forInputTokens: 10), 68)
        XCTAssertEqual(CleanupPrompt.maxOutputTokens(forInputTokens: 250), 548)
    }
}
