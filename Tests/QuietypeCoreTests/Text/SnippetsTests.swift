import XCTest

@testable import QuietypeCore

final class SnippetsTests: XCTestCase {
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
        XCTAssertEqual(
            result.text, "https://github.com/jlee and https://www.linkedin.com/in/jordan-lee are both up to date.")
        XCTAssertEqual(result.used, ["my GitHub", "my LinkedIn"])
    }

    func testEmptyTriggersAreIgnored() {
        XCTAssertEqual(expand("Nothing to see.", [Snippet(trigger: " ... ", text: "boom")]), "Nothing to see.")
        XCTAssertTrue(Snippets([Snippet(trigger: "", text: "x")]).isEmpty)
    }

    func testTriggerNeverSpansPunctuationOrPartOfALongerToken() {
        XCTAssertEqual(expand("Oh my, LinkedIn is down again.", [linkedIn]), "Oh my, LinkedIn is down again.")
        XCTAssertEqual(expand("Visit my linkedin.com page.", [linkedIn]), "Visit my linkedin.com page.")
        XCTAssertEqual(expand("It's on my-linkedin-page.", [linkedIn]), "It's on my-linkedin-page.")
        let work = Snippet(trigger: "work email", text: "jordan@acme.com")
        XCTAssertEqual(
            expand("I'll finish the work. Email me tomorrow.", [work]), "I'll finish the work. Email me tomorrow.")
    }

    func testStoredSentenceDoesNotDoubleThePeriod() {
        let availability = Snippet(trigger: "my availability", text: "I'm free Tuesdays after 2pm.")
        XCTAssertEqual(
            expand("Hi Sam. My availability. Talk soon.", [availability]),
            "Hi Sam. I'm free Tuesdays after 2pm. Talk soon."
        )
    }

    func testHalfFilledSnippetDoesNothing() {
        let unfinished = Snippet(trigger: "my address", text: "")
        XCTAssertEqual(expand("Ship it to my address please.", [unfinished]), "Ship it to my address please.")
        XCTAssertTrue(Snippets([unfinished]).isEmpty)
        XCTAssertTrue(Snippets([Snippet(trigger: "my address", text: "  \n ")]).isEmpty)
    }

    func testTheFirstOfTwoSnippetsWithTheSameTriggerWins() {
        let first = Snippet(trigger: "my email", text: "first@example.com")
        let second = Snippet(trigger: "My E-mail", text: "second@example.com")
        XCTAssertEqual(expand("Use my email.", [first, second]), "Use first@example.com.")
        XCTAssertEqual(expand("Use my email.", [second, first]), "Use second@example.com.")
    }

    func testSnippetsRoundTripAsJSON() throws {
        let snippets = Snippets([linkedIn, signature])
        let decoded = try JSONDecoder().decode(Snippets.self, from: JSONEncoder().encode(snippets))
        XCTAssertEqual(decoded, snippets)
    }

    func testASpecDecodesFromTriggerAndTextAlone() throws {
        let specs = try JSONDecoder().decode(
            [SnippetSpec].self, from: Data(#"[{"trigger": "my GitHub", "text": "https://github.com/jlee"}]"#.utf8))
        XCTAssertEqual(specs, [SnippetSpec(trigger: "my GitHub", text: "https://github.com/jlee")])
        let snippet = specs[0].snippet
        XCTAssertEqual(snippet.trigger, "my GitHub")
        XCTAssertEqual(snippet.text, "https://github.com/jlee")
        XCTAssertEqual(Snippets([snippet]).expand("See my GitHub.").text, "See https://github.com/jlee.")
    }
}
