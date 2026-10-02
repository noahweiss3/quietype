import XCTest
@testable import MurmurCore

final class RulesTests: XCTestCase {
    private func clean(_ text: String) -> String { Rules.apply(text).text }

    func testRemovesFillersAndRecapitalizes() {
        XCTAssertEqual(clean("Um, so we should ship it."), "So we should ship it.")
        XCTAssertEqual(clean("I was, um, thinking about it."), "I was thinking about it.")
        XCTAssertEqual(clean("So, uh, we should go."), "So, we should go.")
        XCTAssertEqual(clean("We could uh meet on Tuesday."), "We could meet on Tuesday.")
        XCTAssertEqual(clean("That's done. Um, next thing is the budget."), "That's done. Next thing is the budget.")
        XCTAssertEqual(clean("Uh."), "")
    }

    func testFillerAtSentenceEndKeepsThePeriod() {
        XCTAssertEqual(clean("Let's call it a day, um. Tomorrow we start."), "Let's call it a day. Tomorrow we start.")
    }

    func testLeavesWordsThatOnlyLookLikeFillers() {
        XCTAssertEqual(clean("Take her to the ER now."), "Take her to the ER now.")
        XCTAssertEqual(clean("I like it, you know."), "I like it, you know.")
    }

    func testCollapsesStuttersButKeepsIntentionalRepeats() {
        XCTAssertEqual(clean("I I think the the plan works."), "I think the plan works.")
        XCTAssertEqual(clean("It was very very good."), "It was very very good.")
        XCTAssertEqual(clean("He had had enough."), "He had had enough.")
        XCTAssertEqual(clean("Call 555 555 1234."), "Call 555 555 1234.")
    }

    func testStartOverDropsEverythingBefore() {
        XCTAssertEqual(clean("This is all wrong. Start over. Hi Sam, quick question."), "Hi Sam, quick question.")
        XCTAssertEqual(clean("Okay, let me start over. hey team"), "Hey team")
        XCTAssertEqual(clean("Never mind this, start over, the meeting moved to Friday."), "The meeting moved to Friday.")
        XCTAssertEqual(clean("Ugh. Start over."), "")
    }

    func testStartOverInsideASentenceIsLeftForTheLLM() {
        let result = Rules.apply("We had to start over on the design.")
        XCTAssertEqual(result.text, "We had to start over on the design.")
        XCTAssertTrue(result.cues.contains(.correction))
    }

    func testCues() {
        XCTAssertEqual(Rules.apply("See you at noon.").cues, [])
        XCTAssertEqual(Rules.apply("Meet at 3, no wait, 4.").cues, [.correction])
        XCTAssertEqual(Rules.apply("First eggs, second milk, third bread.").cues, [.list])
        XCTAssertEqual(Rules.apply("1. eggs 2. milk").cues, [.list])
        XCTAssertEqual(Rules.apply("Hi new paragraph thanks").cues, [.formatting])
        XCTAssertTrue(Rules.apply("I'll be late. Scratch that.").needsLLM)
    }

    func testFallbackScratchThatDropsThePreviousSentence() {
        XCTAssertEqual(
            Rules.applyFallbackCorrections("I'll be there at noon. Scratch that. I'll be there at one."),
            "I'll be there at one."
        )
        XCTAssertEqual(
            Rules.applyFallbackCorrections("First line. Second line. Delete that."),
            "First line."
        )
    }

    func testFallbackScratchThatMidSentenceDropsOneWord() {
        XCTAssertEqual(Rules.applyFallbackCorrections("I'll meet you at 3, scratch that, 4."), "I'll meet you at 4.")
    }

    func testFallbackLeavesOrdinaryUseAlone() {
        XCTAssertEqual(Rules.applyFallbackCorrections("Don't scratch that table."), "Don't scratch that table.")
    }

    func testWordSplitting() {
        let word = Word("\"don't,")
        XCTAssertEqual(word.leading, "\"")
        XCTAssertEqual(word.core, "don't")
        XCTAssertEqual(word.trailing, ",")
        var iphone = Word(core: "iPhone")
        iphone.capitalize()
        XCTAssertEqual(iphone.core, "iPhone")
    }
}
