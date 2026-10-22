import XCTest

@testable import QuietypeCore

final class MeetingNotesWriterTests: XCTestCase {
    private actor FakeGenerator: TextGenerator {
        var requests: [[ChatMessage]] = []
        var replies: [String]

        init(replies: [String]) { self.replies = replies }

        func generate(_ messages: [ChatMessage], maxTokens: Int) async throws -> String {
            requests.append(messages)
            return replies.isEmpty ? "" : replies.removeFirst()
        }
    }

    private let notesA =
        "## Summary\n- Beta timing\n## Decisions\n- None yet\n## Action items\n- [ ] You: write release notes\n## Open questions\n- None yet"
    private let notesB =
        "## Summary\n- Beta ships Thursday\n## Decisions\n- Ship Thursday\n## Action items\n- [ ] You: write release notes\n## Open questions\n- None yet"

    func testFoldsNewSegmentsIntoTheNotes() async {
        let generator = FakeGenerator(replies: [notesA, notesB])
        let writer = MeetingNotesWriter(generator: generator)
        var transcript = MeetingTranscript(segments: [segment(0, .others, 1, 4, "When does the beta ship?")])

        let first = await writer.update(with: transcript)
        XCTAssertTrue(first)
        let afterFirst = await writer.notes
        XCTAssertEqual(afterFirst, notesA)
        let noNews = await writer.update(with: transcript)
        XCTAssertFalse(noNews, "nothing new to fold in")

        transcript.add(segment(1, .me, 5, 8, "Let's say Thursday."))
        let second = await writer.update(with: transcript)
        XCTAssertTrue(second)
        let requests = await generator.requests
        XCTAssertEqual(requests.count, 2)
        // The second request carries the current notes and only the new line.
        let content = requests[1][1].content
        XCTAssertTrue(content.contains("- Beta timing"))
        XCTAssertTrue(content.contains("[00:05] You: Let's say Thursday."))
        XCTAssertFalse(content.contains("When does the beta ship?"))
        let notes = await writer.notes
        XCTAssertEqual(notes, notesB)
    }

    func testRejectsOutputThatIsNotNotes() async {
        let writer = MeetingNotesWriter(generator: FakeGenerator(replies: ["Sure! Here's a summary of the meeting."]))
        let ok = await writer.update(with: MeetingTranscript(segments: [segment(0, .me, 0, 2, "Hello everyone.")]))
        XCTAssertFalse(ok)
        let notes = await writer.notes
        XCTAssertEqual(notes, "")
        let error = await writer.lastError
        XCTAssertNotNil(error)
        let pending = await writer.pendingWords(
            in: MeetingTranscript(segments: [segment(0, .me, 0, 2, "Hello everyone.")]))
        XCTAssertEqual(pending, 2, "a failed update leaves the segment pending")
    }

    func testFinalPassRereadsAShortMeetingInFull() async {
        let generator = FakeGenerator(replies: [notesA, notesB])
        let writer = MeetingNotesWriter(generator: generator)
        let transcript = MeetingTranscript(segments: [segment(0, .me, 0, 2, "Hello everyone.")])
        _ = await writer.update(with: transcript)
        let final = await writer.update(with: transcript, final: true)
        XCTAssertTrue(final)
        let content = await generator.requests[1][1].content
        XCTAssertTrue(content.contains("[00:00] You: Hello everyone."), "the whole transcript again")
        XCTAssertTrue(content.contains("complete transcript"))
        XCTAssertFalse(content.contains("- Beta timing"), "a fresh read, so early slips can't carry over")
        let notes = await writer.notes
        XCTAssertEqual(notes, notesB)
    }

    func testFailedFinalReadFallsBackToTheRunningNotes() async {
        let generator = FakeGenerator(replies: [notesA, "garbled", "still garbled", notesB])
        let writer = MeetingNotesWriter(generator: generator)
        let transcript = MeetingTranscript(segments: [segment(0, .me, 0, 2, "Hello everyone.")])
        _ = await writer.update(with: transcript)
        let final = await writer.update(with: transcript, final: true)
        XCTAssertTrue(final)
        let requests = await generator.requests
        XCTAssertEqual(requests.count, 4, "full read, its retry, then the tidy-up of the running notes")
        XCTAssertTrue(requests[3][1].content.contains("- Beta timing"))
        let notes = await writer.notes
        XCTAssertEqual(notes, notesB)
    }

    func testAFailedAnswerIsRetriedAskingForShorterNotes() async {
        let cutOff = "## Summary\n- Beta timing\n## Decisions\n- None yet\n## Action items\n- [ ] You: write rel"
        let generator = FakeGenerator(replies: [cutOff, notesA])
        let writer = MeetingNotesWriter(generator: generator)
        let ok = await writer.update(with: MeetingTranscript(segments: [segment(0, .me, 0, 2, "Hello everyone.")]))
        XCTAssertTrue(ok)
        let requests = await generator.requests
        XCTAssertFalse(requests[0][1].content.contains("getting long"))
        XCTAssertTrue(requests[1][1].content.contains("getting long"))
    }

    func testARetryOfLongNotesAsksForShorterNotesThanTheFirstTry() async {
        let bullets = (0..<40).map { "- Topic number \($0) was discussed at some length today" }.joined(separator: "\n")
        let longNotes =
            "## Summary\n\(bullets)\n## Decisions\n- None yet\n## Action items\n- None yet\n## Open questions\n- None yet"
        let cutOff = "## Summary\n- Topic number 1\n## Decisions\n- None yet\n## Action items\n- [ ] You: write rel"
        let generator = FakeGenerator(replies: [longNotes, cutOff, notesA])
        let writer = MeetingNotesWriter(generator: generator)
        var transcript = MeetingTranscript(segments: [segment(0, .me, 0, 2, "Hello everyone.")])
        _ = await writer.update(with: transcript)
        transcript.add(segment(1, .others, 3, 5, "Hi there."))
        let ok = await writer.update(with: transcript)
        XCTAssertTrue(ok)
        let requests = await generator.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests[1][1].content.contains("getting long"))
        XCTAssertFalse(requests[1][1].content.contains("cut off"))
        XCTAssertTrue(requests[2][1].content.contains("cut off"))
        XCTAssertNotEqual(requests[1][1].content, requests[2][1].content)
    }

    func testLongNotesAreMergedDownOnTheNextUpdate() async {
        let bullets = (0..<40).map { "- Topic number \($0) was discussed at some length today" }.joined(separator: "\n")
        let longNotes =
            "## Summary\n\(bullets)\n## Decisions\n- None yet\n## Action items\n- None yet\n## Open questions\n- None yet"
        let generator = FakeGenerator(replies: [longNotes, notesA])
        let writer = MeetingNotesWriter(generator: generator)
        var transcript = MeetingTranscript(segments: [segment(0, .me, 0, 2, "Hello everyone.")])
        _ = await writer.update(with: transcript)
        transcript.add(segment(1, .others, 3, 5, "Hi there."))
        _ = await writer.update(with: transcript)
        let requests = await generator.requests
        XCTAssertTrue(requests[1][1].content.contains("getting long"))
    }

    func testFinalReadBudgetFitsTheNotesContext() {
        let transcriptTokens = MeetingNotesWriter.fullFinalPassWords * 17 / 10
        XCTAssertLessThanOrEqual(
            transcriptTokens + MeetingNotesPrompt.maxOutputTokens + 1_200, MeetingNotesPrompt.contextTokens
        )
        XCTAssertGreaterThan(
            MeetingNotesWriter.fullFinalPassWords, 1_500, "a 10-15 minute meeting still gets the full read")
    }

    func testFinalPassOnALongMeetingOnlyTidiesTheNotes() async {
        let long = Array(repeating: "word", count: 400).joined(separator: " ")
        let segments = (0..<7).map { segment($0, .others, Double($0 * 60), Double($0 * 60 + 50), long) }
        let transcript = MeetingTranscript(segments: segments)
        XCTAssertFalse(MeetingNotesWriter.finalPassReadsEverything(transcript))
        let generator = FakeGenerator(replies: Array(repeating: notesA, count: 5))
        let writer = MeetingNotesWriter(generator: generator)
        _ = await writer.update(with: transcript)
        let final = await writer.update(with: transcript, final: true)
        XCTAssertTrue(final)
        let requests = await generator.requests
        XCTAssertEqual(requests.count, 5, "four batches of at most 900 words, then the tidy-up")
        XCTAssertTrue(requests[4][1].content.contains("(no new speech)"))
        XCTAssertTrue(requests[4][1].content.contains("The meeting has ended"))
    }

    func testLongBacklogsAreSplitIntoBatches() {
        let long = Array(repeating: "word", count: 400).joined(separator: " ")
        let segments = (0..<3).map { segment($0, .others, Double($0 * 60), Double($0 * 60 + 50), long) }
        XCTAssertEqual(MeetingNotesWriter.batches(segments).map { $0.map(\.id) }, [[0, 1], [2]])
    }
}
