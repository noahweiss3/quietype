import XCTest

@testable import QuietypeCore

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
        XCTAssertEqual(
            clean("Never mind this, start over, the meeting moved to Friday."), "The meeting moved to Friday.")
        XCTAssertEqual(clean("Ugh. Start over."), "")
    }

    func testStartOverInsideASentenceIsLeftForTheLLM() {
        let result = Rules.apply("We had to start over on the design.")
        XCTAssertEqual(result.text, "We had to start over on the design.")
        XCTAssertTrue(result.cues.contains(.correction))
    }

    func testCuesFlagCorrectionsListsAndFormattingForTheLLM() {
        XCTAssertEqual(Rules.apply("See you at noon.").cues, [])
        XCTAssertEqual(Rules.apply("Meet at 3, no wait, 4.").cues, [.correction])
        XCTAssertEqual(Rules.apply("First eggs, second milk, third bread.").cues, [.list])
        XCTAssertEqual(Rules.apply("1. eggs 2. milk").cues, [.list])
        XCTAssertEqual(Rules.apply("Hi new paragraph thanks").cues, [.formatting])
        XCTAssertTrue(Rules.apply("I'll be late. Scratch that. I'll be early.").needsLLM)
    }

    func testOpeningCommandIsDropped() {
        XCTAssertEqual(
            clean("Let me rephrase. Can we move the deadline by a week?"), "Can we move the deadline by a week?")
        XCTAssertEqual(clean("Okay, scratch that. the meeting is on Wednesday."), "The meeting is on Wednesday.")
        XCTAssertEqual(clean("Let me rephrase that, can we talk tomorrow?"), "Can we talk tomorrow?")
        // Only as an opening command.
        XCTAssertEqual(
            clean("Let me rephrase the question for the team."), "Let me rephrase the question for the team.")
        XCTAssertFalse(Rules.apply("Let me rephrase. Can we move the deadline by a week?").needsLLM)
        XCTAssertEqual(clean("Scratch that."), "Scratch that.", "nothing follows, so the fallback decides")
    }

    func testClosingScratchThatDropsTheSentenceBefore() {
        XCTAssertEqual(clean("Send the invoice to Acme today. Scratch that."), "")
        XCTAssertEqual(
            clean("Thanks for the update. Also, your numbers are wrong. Scratch that."), "Thanks for the update.")
        XCTAssertEqual(clean("Can you grab coffee? Um, never mind."), "")
        XCTAssertEqual(
            clean("Looks good to me. The tests are flaky though. Actually, I take that back."), "Looks good to me.")
        // Only a standalone closing command counts.
        XCTAssertEqual(clean("She said scratch that."), "She said scratch that.")
        XCTAssertEqual(clean("I want pizza and wings, scrap that."), "I want pizza and wings, scrap that.")
        XCTAssertEqual(clean("Never mind the noise, the call went fine."), "Never mind the noise, the call went fine.")
        // On its own the command is the message.
        XCTAssertEqual(clean("Never mind."), "Never mind.")
        XCTAssertEqual(clean("No, forget it."), "No, forget it.")
        // "Mr." and "p.m." don't end the sentence being taken back.
        XCTAssertEqual(clean("I'll call Mr. Johnson later. Scratch that."), "")
        XCTAssertEqual(clean("Thanks. Let's meet at 3 p.m. tomorrow. Never mind."), "Thanks.")
    }

    func testRevisionCues() {
        let revisions = [
            "I want pizza and wings, scrap that, not the wings.",
            "Can you add eggs, milk, and butter to the list? Wait, skip the butter.",
            "Invite Sam and Jordan to the review. Actually, not Jordan.",
            "Send the deck to marketing and sales, no, just marketing.",
            "Add Tom to the thread, I meant Tim.",
            "Let's go with option A. On second thought, option B.",
            "Bring snacks. Oh, and also drinks.",
            "Book flights for Monday and Tuesday. Oh wait, take out Tuesday.",
            "We need chairs, tables, and a projector. Forget the projector.",
            "Add a note about the delay and one about pricing. Delete the last one.",
            "Book a table for Friday. Forget that, make it Saturday.",
            "Grab two coffees and a muffin, just the coffees.",
            "Bring snacks. Oh, and drinks.",
            "The bug is in the parser. No, the lexer.",
        ]
        for text in revisions {
            XCTAssertTrue(Rules.apply(text).cues.contains(.correction), text)
        }
        // The same words as ordinary text: nothing before them to revise.
        let ordinary = [
            "Skip the intro and go straight to the demo.",
            "We decided to drop the offsite this year.",
            "No, I don't think that works for us.",
            "Never mind the noise in the background, the call went fine.",
            "Actually, the numbers look better than I expected.",
            "Make it quick, we only have ten minutes.",
            "I want pizza, not wings.",
            "Okay. Not sure yet, let me check.",
            "Thanks for the help, just wanted to say hi.",
            "Who is this for, by the way?",
            "Plan A, then plan B.",
            "Did you get my email? No, not yet? Okay, I'll resend it.",
        ]
        for text in ordinary {
            XCTAssertFalse(Rules.apply(text).cues.contains(.correction), text)
        }
    }

    func testTakeBacksThatSplitOrPointAtWhatWasSaid() {
        let revisions = [
            "Pack the cooler, the chairs and the grill. Leave the grill out.",
            "Invite the twins, Omar and Lucia. Cross Lucia off.",
            "Repaint the fence and the shed, strike the shed.",
            "Order the blue rug and the lamp. Ignore what I said about the lamp.",
            "Our goals are speed, cost and hiring. Swap hiring for retention.",
            "We fly out on the fifth, my bad, the sixth.",
            "Rent a van for thirty boxes, let's say forty.",
        ]
        for text in revisions {
            XCTAssertTrue(Rules.apply(text).cues.contains(.correction), text)
        }
        let ordinary = [
            "Take your shoes off at the door, please.",
            "We need to strike a balance between speed and quality.",
            "Everyone except the interns gets a bonus this year.",
            "Swap the winter tires for summer ones in April.",
            "My bad, I forgot to attach the file.",
            "I took the cover off and cleaned the fan.",
            "Forget what I said earlier, I trust your call.",
            "The kids want pizza without onions.",
        ]
        for text in ordinary {
            XCTAssertFalse(Rules.apply(text).cues.contains(.correction), text)
        }
    }

    func testAFillerPausingACorrectionKeepsItsComma() {
        let rephrase = Rules.apply("Hi Sam, I was going to ask if you, um, let me rephrase that. Are you free Monday?")
        XCTAssertEqual(rephrase.text, "Hi Sam, I was going to ask if you, let me rephrase that. Are you free Monday?")
        XCTAssertTrue(rephrase.cues.contains(.correction))

        let number = Rules.apply("The table is for six people, uh, eight.")
        XCTAssertEqual(number.text, "The table is for six people, eight.")
        XCTAssertTrue(number.cues.contains(.correction))

        // An ordinary hesitation still loses its commas and stays on the fast path.
        let hesitation = Rules.apply("I was, um, thinking we could go.")
        XCTAssertEqual(hesitation.text, "I was thinking we could go.")
        XCTAssertFalse(hesitation.cues.contains(.correction))
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
        XCTAssertEqual(Rules.applyFallbackCorrections("I'll meet you at 3, scrap that, 4."), "I'll meet you at 4.")
    }

    func testFallbackLeavesOrdinaryUseAlone() {
        XCTAssertEqual(Rules.applyFallbackCorrections("Don't scratch that table."), "Don't scratch that table.")
        XCTAssertEqual(Rules.applyFallbackCorrections("Okay, scrap that plan."), "Okay, scrap that plan.")
        XCTAssertEqual(
            Rules.applyFallbackCorrections("The prototype failed. Scrap that idea, it does not work."),
            "The prototype failed. Scrap that idea, it does not work."
        )
    }

    func testEverySpokenCommandIsLeftForTheLLM() {
        for command in Rules.layoutCommands + Rules.punctuationCommands {
            let result = Rules.apply("Hi Sam \(command) see you soon")
            XCTAssertEqual(result.cues, [.formatting], command)
            XCTAssertEqual(result.text, "Hi Sam \(command) see you soon", "the LLM does the converting: \(command)")
        }
        XCTAssertEqual(Rules.apply("Hello comma Sam").cues, [.formatting])
        XCTAssertEqual(Rules.apply("Hello, comma, Sam.").cues, [.formatting])
        XCTAssertEqual(Rules.apply("Are we still on for lunch question mark").cues, [.formatting])
        XCTAssertEqual(Rules.apply("That's final period").cues, [.formatting])
        XCTAssertEqual(Rules.apply("Dear team colon the build is green").cues, [.formatting])
        XCTAssertEqual(Rules.apply("We ship Friday Full Stop").cues, [.formatting])
    }

    func testPunctuationTalkedAboutRatherThanDictatedStaysOnTheFastPath() {
        for text in [
            "Put a comma after the greeting.",
            "The comma in that sentence is wrong.",
            "I love the Oxford comma.",
            "Send it as a comma-separated list.",
            "Too many commas here.",
            "Comma placement matters.",
            "The trial period ends Friday.",
            "It got better over the period of a month.",
            "He was screened for colon cancer.",
            "Use a semicolon here.",
            "There's a question mark over the date.",
            "The car came to a full stop.",
            "Swap the em dash for a hyphen.",
        ] {
            XCTAssertEqual(Rules.apply(text).cues, [], text)
        }
    }
}
