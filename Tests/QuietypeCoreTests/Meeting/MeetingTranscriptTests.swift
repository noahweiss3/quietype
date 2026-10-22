import XCTest

@testable import QuietypeCore

final class MeetingTranscriptTests: XCTestCase {
    func testKeepsSegmentsInStartOrder() {
        var transcript = MeetingTranscript()
        transcript.add(segment(0, .others, 10, 14, "Can everyone see my screen?"))
        transcript.add(segment(1, .me, 2, 6, "Morning, let's get started."))
        transcript.add(segment(2, .me, 15, 17, "Yes, looks good."))
        XCTAssertEqual(transcript.segments.map(\.id), [1, 0, 2])
        XCTAssertEqual(transcript.wordCount, 4 + 5 + 3)
    }

    func testDropsEmptySegments() {
        var transcript = MeetingTranscript()
        XCTAssertFalse(transcript.add(segment(0, .me, 0, 1, "  ")))
        XCTAssertTrue(transcript.segments.isEmpty)
    }

    func testMicEchoOfTheCallIsDroppedWhicheverArrivesFirst() {
        let call = segment(0, .others, 30, 36, "We should ship the beta on Thursday and collect feedback.")
        let echo = segment(1, .me, 30.4, 36.2, "ship the beta on Thursday and collect feedback")

        var callFirst = MeetingTranscript()
        callFirst.add(call)
        XCTAssertFalse(callFirst.add(echo))
        XCTAssertEqual(callFirst.segments.map(\.id), [0])

        var echoFirst = MeetingTranscript()
        echoFirst.add(echo)
        echoFirst.add(call)
        XCTAssertEqual(echoFirst.segments.map(\.id), [0])
    }

    func testOwnSpeechOverlappingTheCallIsKept() {
        var transcript = MeetingTranscript()
        transcript.add(segment(0, .others, 30, 36, "We should ship the beta on Thursday."))
        XCTAssertTrue(transcript.add(segment(1, .me, 34, 38, "Thursday works, but I need the release notes first.")))
        // The same words much later aren't an echo.
        XCTAssertTrue(transcript.add(segment(2, .me, 120, 124, "We should ship the beta on Thursday.")))
        XCTAssertEqual(transcript.segments.count, 3)
    }

    func testAQuickReplyReusingTheCallsWordsIsKept() {
        var transcript = MeetingTranscript()
        transcript.add(segment(0, .others, 30, 36.3, "Let's do the demo Thursday at three."))
        XCTAssertTrue(transcript.add(segment(1, .me, 36.4, 38, "Thursday at three works.")))
        XCTAssertEqual(transcript.segments.count, 2)
    }

    func testEchoSpanningTwoCallSegmentsIsDropped() {
        var transcript = MeetingTranscript()
        transcript.add(segment(0, .others, 0, 12.3, "alpha bravo charlie delta echo foxtrot golf hotel india juliet"))
        transcript.add(segment(1, .others, 12.3, 28.3, "kilo lima mike november oscar papa quebec romeo sierra tango"))
        XCTAssertFalse(
            transcript.add(segment(2, .me, 6, 24, "foxtrot golf hotel india juliet kilo lima mike november oscar")))
        XCTAssertEqual(transcript.segments.map(\.id), [0, 1])
    }

    func testTimestampsFormatAsMinutesOrHoursAndLinesNameTheSpeaker() {
        XCTAssertEqual(MeetingTranscript.timestamp(5), "00:05")
        XCTAssertEqual(MeetingTranscript.timestamp(245.9), "04:05")
        XCTAssertEqual(MeetingTranscript.timestamp(3723), "1:02:03")
        XCTAssertEqual(segment(0, .me, 65, 70, "Hi all.").line, "[01:05] You: Hi all.")
        XCTAssertEqual(segment(0, .others, 3, 4, "Hey.").line, "[00:03] Others: Hey.")
    }

    func testMarkdownHasNotesThenTranscript() {
        let transcript = MeetingTranscript(segments: [segment(0, .me, 1, 2, "Hello.")])
        let markdown = transcript.markdown(title: "Weekly sync", notes: "## Summary\n- Greetings")
        XCTAssertEqual(
            markdown, "# Weekly sync\n\n## Summary\n- Greetings\n\n## Transcript\n\n**[00:01] You:** Hello.\n")
    }
}
