import XCTest
@testable import MurmurCore

final class SnippetTests: XCTestCase {
    private let linkedIn = Snippet(trigger: "my LinkedIn", text: "https://www.linkedin.com/in/jordan-lee")
    private let signature = Snippet(trigger: "my email signature", text: "Best,\nJordan Lee\nAcme Corp")

    private func expand(_ text: String, _ snippets: [Snippet]) -> String {
        Snippets(snippets).expand(text).text
    }

    func testExpandsInsideASentence() {
        let result = Snippets([linkedIn]).expand("You can find me at my LinkedIn, let's connect.")
        XCTAssertEqual(result.text, "You can find me at https://www.linkedin.com/in/jordan-lee, let's connect.")
        XCTAssertEqual(result.used, ["my LinkedIn"])
    }

    func testMatchingIgnoresCasePunctuationAndSpacing() {
        let url = "https://www.linkedin.com/in/jordan-lee"
        XCTAssertEqual(expand("Here's my linked in.", [linkedIn]), "Here's \(url).")
        XCTAssertEqual(expand("Here's MY LINKEDIN!", [linkedIn]), "Here's \(url)!")
        XCTAssertEqual(expand("Here's my Linked-In", [linkedIn]), "Here's \(url)")
    }

    func testOnlyWholeWordsMatch() {
        XCTAssertEqual(expand("The army LinkedIn group is busy.", [linkedIn]), "The army LinkedIn group is busy.")
        XCTAssertEqual(expand("Tommy LinkedIn", [linkedIn]), "Tommy LinkedIn")
        XCTAssertEqual(expand("my Linked", [linkedIn]), "my Linked")
    }

    func testDictationThatIsOnlyTheTriggerBecomesExactlyTheText() {
        XCTAssertEqual(expand("My email signature.", [signature]), "Best,\nJordan Lee\nAcme Corp")
        XCTAssertEqual(expand("my linkedin", [linkedIn]), "https://www.linkedin.com/in/jordan-lee")
    }

    func testBlockAtTheEndDropsTheTrailingPeriod() {
        XCTAssertEqual(
            expand("Thanks again for your help.\n\nMy email signature.", [signature]),
            "Thanks again for your help.\n\nBest,\nJordan Lee\nAcme Corp"
        )
    }

    func testLongestTriggerWins() {
        let work = Snippet(trigger: "my email", text: "jordan@personal.com")
        let workEmail = Snippet(trigger: "my work email", text: "jordan@acme.com")
        XCTAssertEqual(expand("Use my work email please.", [work, workEmail]), "Use jordan@acme.com please.")
        XCTAssertEqual(expand("Use my email please.", [work, workEmail]), "Use jordan@personal.com please.")
    }

    func testSeveralSnippetsInOneDictation() {
        let github = Snippet(trigger: "my GitHub", text: "https://github.com/jlee")
        let result = Snippets([linkedIn, github]).expand("My GitHub and my LinkedIn are both up to date.")
        XCTAssertEqual(result.text, "https://github.com/jlee and https://www.linkedin.com/in/jordan-lee are both up to date.")
        XCTAssertEqual(result.used, ["my GitHub", "my LinkedIn"])
    }

    func testEmptyTriggersAreIgnored() {
        XCTAssertEqual(expand("Nothing to see.", [Snippet(trigger: " ... ", text: "boom")]), "Nothing to see.")
        XCTAssertTrue(Snippets([Snippet(trigger: "", text: "x")]).isEmpty)
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
        struct FakeCleaner: TextCleaner {
            func clean(_ dictation: String, style: WritingStyle, vocabulary: [String]) async throws -> String {
                "Send them my GitHub."
            }
        }
        let github = Snippet(trigger: "my GitHub", text: "https://github.com/jlee")
        let context = DictationContext(snippets: Snippets([linkedIn, github]), appendTrailingSpace: false)
        let result = await DictationProcessor(cleaner: FakeCleaner()).process("Send them my LinkedIn, no wait, my GitHub.", context: context)
        XCTAssertEqual(result.path, .llm)
        XCTAssertEqual(result.text, "Send them https://github.com/jlee.")
        XCTAssertEqual(result.snippets, ["my GitHub"])
    }

    func testSnippetsRoundTripAsJSON() throws {
        let snippets = Snippets([linkedIn, signature])
        let decoded = try JSONDecoder().decode(Snippets.self, from: JSONEncoder().encode(snippets))
        XCTAssertEqual(decoded, snippets)
    }
}
