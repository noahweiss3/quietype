import XCTest

@testable import QuietypeCore

final class MeetingNotesPromptTests: XCTestCase {
    private let notesA =
        "## Summary\n- Beta timing\n## Decisions\n- None yet\n## Action items\n- [ ] You: write release notes\n## Open questions\n- None yet"

    func testWrappersAroundTheNotesAreStrippedAndIncompleteNotesAreRejected() {
        let wrapped = "<think>\nok\n</think>\nHere are the notes:\n```markdown\n\(notesA)\n```"
        XCTAssertEqual(MeetingNotesPrompt.sanitize(wrapped), notesA)
        XCTAssertNil(MeetingNotesPrompt.sanitize("## Summary\n- Only a summary"))
    }

    func testTrailingChatterIsDroppedAndCutOffNotesAreRejected() {
        let chatty = notesA + "  \n\nLet me know if you'd like me to adjust anything!"
        XCTAssertEqual(MeetingNotesPrompt.sanitize(chatty), notesA)
        let wrappedBullet =
            "## Summary\n- A long bullet that\n  wraps onto the next line\n## Decisions\n- None yet\n## Action items\n- None yet\n## Open questions\n- None yet"
        XCTAssertEqual(
            MeetingNotesPrompt.sanitize(wrappedBullet)?.split(separator: "\n")[1],
            "- A long bullet that wraps onto the next line")
        let cutOff = "## Summary\n- Beta timing\n## Decisions\n- None yet\n## Action items\n- [ ] You: write release no"
        XCTAssertNil(MeetingNotesPrompt.sanitize(cutOff), "no Open questions section: the answer was cut off")
    }

    func testNamesFromIntroductionsAndAddress() {
        let call = [
            segment(0, .me, 3, 9, "Hi Dana, thanks for making time."),
            segment(1, .others, 10, 14, "Happy to. Overall it's been good."),
            segment(2, .me, 150, 152, "Noted, early December. Thanks Dana, talk soon."),
        ]
        XCTAssertEqual(MeetingNotesPrompt.names(in: call), ["Dana"])
        let sync = [
            segment(0, .others, 12, 20, "Morning. Priya here. Quick status first."),
            segment(1, .others, 21, 30, "This is Marcus. Same on my side."),
            segment(2, .me, 78, 84, "Next, onboarding emails. Marcus, where are we?"),
            segment(3, .others, 113, 120, "Priya. Who's sending the survey results?"),
            segment(4, .me, 151, 158, "Yes, let's do that. Okay, sounds good."),
        ]
        XCTAssertEqual(MeetingNotesPrompt.names(in: sync), ["Priya", "Marcus"])
        let noNames = [
            segment(0, .others, 0, 3, "Exactly. The renewal is forty seats."),
            segment(1, .others, 4, 6, "Same here."),
            segment(2, .others, 7, 9, "It's Thursday, so we can ship."),
            segment(3, .me, 10, 12, "Alright, what's next?"),
            segment(4, .me, 13, 15, "Now, can we talk pricing?"),
        ]
        XCTAssertEqual(MeetingNotesPrompt.names(in: noNames), [])
        XCTAssertEqual(MeetingNotesPrompt.names(in: [segment(0, .others, 0, 3, "Hi, it's Dana from Acme.")]), ["Dana"])
        let openersAndCompanies = [
            segment(0, .me, 0, 3, "Overall, how did the first year go?"),
            segment(1, .me, 4, 6, "Realistically, what's the timeline?"),
            segment(2, .me, 7, 9, "Thanks Both."),
            segment(3, .others, 10, 12, "Not here yet."),
            segment(4, .others, 13, 15, "It's Acme's biggest account."),
            segment(5, .others, 16, 18, "This is Google Meet acting up."),
        ]
        XCTAssertEqual(MeetingNotesPrompt.names(in: openersAndCompanies), [])
        let saidLowerCase = [
            segment(0, .me, 0, 3, "Still, can we make Friday?"),
            segment(1, .others, 4, 6, "We're still waiting on legal."),
        ]
        XCTAssertEqual(MeetingNotesPrompt.names(in: saidLowerCase), [])
        XCTAssertEqual(
            MeetingNotesPrompt.names(in: [segment(0, .me, 0, 3, "Hi Emily, thanks for joining.")]), ["Emily"])
        let messages = MeetingNotesPrompt.messages(notes: "", newTranscript: "x", isFinal: false, names: ["Dana"])
        let content = messages[1].content
        XCTAssertTrue(content.contains("People named on the call: Dana."))
    }
}
