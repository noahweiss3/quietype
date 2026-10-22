import XCTest

@testable import QuietypeCore

final class DictationProcessorTests: XCTestCase {
    private struct FakeCleaner: TextCleaner {
        var reply: String
        func clean(_ dictation: String, style: WritingStyle, vocabulary: [String]) async throws -> String { reply }
    }

    private struct CutOff: Error {}

    private struct ThrowingCleaner: TextCleaner {
        func clean(_ dictation: String, style: WritingStyle, vocabulary: [String]) async throws -> String {
            throw CutOff()
        }
    }

    private struct RejectedCleaner: TextCleaner {
        func clean(_ dictation: String, style: WritingStyle, vocabulary: [String]) async throws -> String {
            "Sure! Here's a poem about the sea and the sky and everything in between."
        }
    }

    private let linkedIn = Snippet(trigger: "my LinkedIn", text: "https://www.linkedin.com/in/jordan-lee")

    func testSmartModeSkipsTheLLMForPlainDictation() async {
        let processor = DictationProcessor(cleaner: FakeCleaner(reply: "SHOULD NOT BE USED"))
        let result = await processor.process("Um, see you at noon.", context: DictationContext(mode: .smart))
        XCTAssertEqual(result.text, "See you at noon. ")
        XCTAssertEqual(result.path, .rules)
        XCTAssertNil(result.llmSeconds)
    }

    func testSmartModeUsesTheLLMForCorrections() async {
        let processor = DictationProcessor(cleaner: FakeCleaner(reply: "Let's meet at 4."))
        let result = await processor.process("Let's meet at 3, no wait, 4.", context: DictationContext(mode: .smart))
        XCTAssertEqual(result.text, "Let's meet at 4. ")
        XCTAssertEqual(result.path, .llm)
    }

    func testRejectedLLMFallsBackToRules() async {
        let processor = DictationProcessor(
            cleaner: FakeCleaner(reply: "Sure! Here's a poem about the sea and the sky and everything in between."))
        let result = await processor.process(
            "I'll be late. Scratch that. I'll be on time.", context: DictationContext(mode: .smart))
        XCTAssertEqual(result.path, .llmRejected)
        XCTAssertEqual(result.text, "I'll be on time. ")
    }

    /// A cleaner that throws, as the on-device model does for an answer cut off at its token limit,
    /// must fall back exactly as a rejected answer does rather than paste anything it produced.
    func testFailedCleanupFallsBackLikeARejectedAnswer() async {
        let dictation = "I'll be late. Scratch that. I'll be on time."
        let failed = await DictationProcessor(cleaner: ThrowingCleaner()).process(
            dictation, context: DictationContext(mode: .smart))
        let rejected = await DictationProcessor(cleaner: RejectedCleaner()).process(
            dictation, context: DictationContext(mode: .smart))

        XCTAssertEqual(failed.path, .llmRejected)
        XCTAssertEqual(failed.text, rejected.text)
        XCTAssertEqual(failed.text, "I'll be on time. ")
        XCTAssertNotNil(failed.llmSeconds)
        XCTAssertTrue(failed.note?.hasPrefix("cleanup failed:") ?? false, failed.note ?? "no note")
    }

    func testCodeStyleDropsLonePeriodAndTrailingSpace() async {
        let processor = DictationProcessor(cleaner: nil)
        let result = await processor.process("git status.", context: DictationContext(style: .code))
        XCTAssertEqual(result.text, "git status")
    }

    func testProcessorExpandsAfterTheDictionaryAndKeepsTheTextVerbatim() async {
        let snippet = Snippet(trigger: "my zoom", text: "https://zoom.us/j/123 (passcode kubernetes)")
        let context = DictationContext(
            mode: .rulesOnly,
            dictionary: PersonalDictionary(terms: ["Kubernetes"]),
            snippets: Snippets([snippet]),
            appendTrailingSpace: false
        )
        let result = await DictationProcessor(cleaner: nil).process("Um, join my zoom at noon.", context: context)
        XCTAssertEqual(result.text, "Join https://zoom.us/j/123 (passcode kubernetes) at noon.")
        XCTAssertEqual(result.snippets, ["my zoom"])
    }

    func testCorrectionsApplyBeforeExpansion() async {
        let github = Snippet(trigger: "my GitHub", text: "https://github.com/jlee")
        let context = DictationContext(snippets: Snippets([linkedIn, github]), appendTrailingSpace: false)
        let result = await DictationProcessor(cleaner: FakeCleaner(reply: "Send them my GitHub.")).process(
            "Send them my LinkedIn, no wait, my GitHub.", context: context)
        XCTAssertEqual(result.path, .llm)
        XCTAssertEqual(result.text, "Send them https://github.com/jlee.")
        XCTAssertEqual(result.snippets, ["my GitHub"])
    }

    func testTriggersSaidInTheDictationAreKeptVerbatimByTheLLM() async {
        final class RecordingCleaner: TextCleaner, @unchecked Sendable {
            var vocabulary: [String] = []
            func clean(_ dictation: String, style: WritingStyle, vocabulary: [String]) async throws -> String {
                self.vocabulary = vocabulary
                return dictation
            }
        }
        let github = Snippet(trigger: "my GitHub", text: "https://github.com/jlee")
        let cleaner = RecordingCleaner()
        let context = DictationContext(
            mode: .always, dictionary: PersonalDictionary(terms: ["Kubernetes"]),
            snippets: Snippets([linkedIn, github])
        )
        _ = await DictationProcessor(cleaner: cleaner).process(
            "Here are my links: first my GitHub, second Kubernetes.", context: context)
        XCTAssertEqual(cleaner.vocabulary, ["Kubernetes", "my GitHub"])
    }

    func testCodeStylePeriodIsDecidedBeforeExpansion() async {
        let repo = Snippet(trigger: "my repo", text: "git@github.com:jlee/quietype.git")
        let context = DictationContext(style: .code, mode: .rulesOnly, snippets: Snippets([repo]))
        let result = await DictationProcessor(cleaner: nil).process("git clone my repo.", context: context)
        XCTAssertEqual(result.text, "git clone git@github.com:jlee/quietype.git")
    }

    func testWholeDictationSnippetStillGetsATrailingSpace() async {
        let calendly = Snippet(trigger: "my calendly link", text: "https://calendly.com/jordan-lee/30min")
        let context = DictationContext(mode: .rulesOnly, snippets: Snippets([calendly]))
        let result = await DictationProcessor(cleaner: nil).process("My calendly link.", context: context)
        XCTAssertEqual(result.text, "https://calendly.com/jordan-lee/30min ")
    }
}
