import XCTest
@testable import MurmurCore

private func tone(_ seconds: Double, amplitude: Float = 0.2) -> [Float] {
    (0..<Int(seconds * 16_000)).map { amplitude * sin(Float($0) * 0.1) }
}

private func silence(_ seconds: Double) -> [Float] { Array(repeating: 0, count: Int(seconds * 16_000)) }

private func segment(_ id: Int, _ speaker: MeetingSpeaker, _ start: Double, _ end: Double, _ text: String) -> MeetingSegment {
    MeetingSegment(id: id, speaker: speaker, start: start, end: end, text: text)
}

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

    func testTimestampsAndLines() {
        XCTAssertEqual(MeetingTranscript.timestamp(5), "00:05")
        XCTAssertEqual(MeetingTranscript.timestamp(245.9), "04:05")
        XCTAssertEqual(MeetingTranscript.timestamp(3723), "1:02:03")
        XCTAssertEqual(segment(0, .me, 65, 70, "Hi all.").line, "[01:05] You: Hi all.")
        XCTAssertEqual(segment(0, .others, 3, 4, "Hey.").line, "[00:03] Others: Hey.")
    }

    func testMarkdownHasNotesThenTranscript() {
        let transcript = MeetingTranscript(segments: [segment(0, .me, 1, 2, "Hello.")])
        let markdown = transcript.markdown(title: "Weekly sync", notes: "## Summary\n- Greetings")
        XCTAssertEqual(markdown, "# Weekly sync\n\n## Summary\n- Greetings\n\n## Transcript\n\n**[00:01] You:** Hello.\n")
    }
}

final class MeetingSegmenterTests: XCTestCase {
    func testLongSpeechWithoutPausesIsCutAtItsQuietestMoment() {
        var segmenter = SpeechSegmenter(minPause: 0.6, minSegment: 3, maxSegment: 20)
        // A short dip at 19 s is too brief to count as a pause, but it's the best place to cut.
        var closed: [Range<Int>] = []
        for chunk in [tone(19), tone(0.3, amplitude: 0.005), tone(6)] {
            closed += segmenter.append(chunk)
        }
        XCTAssertEqual(closed.count, 1)
        let cut = Double(closed[0].upperBound) / 16_000
        XCTAssertGreaterThanOrEqual(cut, 19.0)
        XCTAssertLessThanOrEqual(cut, 19.3)
    }

    func testDictationSegmenterNeverForcesACut() {
        var segmenter = SpeechSegmenter()
        XCTAssertEqual(segmenter.append(tone(45)), [])
    }
}

final class MeetingSessionTests: XCTestCase {
    /// Returns a unique one-word "transcript" per call, naming its length in seconds.
    private actor FakeTranscriber: SpeechTranscriber {
        var calls = 0
        func transcribe(_ samples: [Float]) async throws -> String {
            calls += 1
            return "seg\(calls)len\(Int((Double(samples.count) / 16_000).rounded()))"
        }
    }

    private func feed(_ session: MeetingSession, _ audio: [Float], from speaker: MeetingSpeaker) async {
        for start in stride(from: 0, to: audio.count, by: 4800) {
            await session.append(Array(audio[start..<min(audio.count, start + 4800)]), from: speaker)
        }
    }

    func testTranscribesBothSidesWithTimesAndSpeakers() async {
        let session = MeetingSession(transcriber: FakeTranscriber())
        await feed(session, tone(4) + silence(1) + silence(6), from: .me)
        await feed(session, silence(6) + tone(5), from: .others)
        let transcript = await session.finish()

        XCTAssertEqual(transcript.segments.map(\.speaker), [.me, .others])
        let me = transcript.segments[0], others = transcript.segments[1]
        XCTAssertEqual(me.start, 0, accuracy: 0.01)
        XCTAssertTrue(me.text.hasSuffix("len4"), me.text) // 4 s of speech plus half the pause
        // The call's stretch opens with 6 s of silence; its timestamp starts just before the talking.
        XCTAssertEqual(others.start, 5.8, accuracy: 0.05)
        XCTAssertGreaterThan(others.end, 10.9)
        XCTAssertTrue(transcript.segments.allSatisfy { !$0.text.isEmpty })
    }

    func testSilenceIsNeverTranscribedAndDoesNotPileUp() async {
        let fake = FakeTranscriber()
        let session = MeetingSession(transcriber: fake)
        await feed(session, silence(65), from: .others)
        let transcript = await session.finish()
        XCTAssertTrue(transcript.segments.isEmpty)
        let calls = await fake.calls
        XCTAssertEqual(calls, 0)
    }

    func testReportsEachNewSegment() async {
        let session = MeetingSession(transcriber: FakeTranscriber())
        let counter = Counter()
        await session.setOnUpdate { transcript in Task { await counter.record(transcript.segments.count) } }
        await feed(session, tone(4) + silence(1) + tone(4), from: .me)
        _ = await session.finish()
        try? await Task.sleep(nanoseconds: 50_000_000)
        let seen = await counter.values
        XCTAssertEqual(seen.sorted(), [1, 2])
    }

    private actor Counter {
        var values: [Int] = []
        func record(_ value: Int) { values.append(value) }
    }
}

final class MeetingNotesTests: XCTestCase {
    private actor FakeGenerator: TextGenerator {
        var requests: [[ChatMessage]] = []
        var replies: [String]

        init(replies: [String]) { self.replies = replies }

        func generate(_ messages: [ChatMessage], maxTokens: Int) async throws -> String {
            requests.append(messages)
            return replies.isEmpty ? "" : replies.removeFirst()
        }
    }

    private let notesA = "## Summary\n- Beta timing\n## Decisions\n- None yet\n## Action items\n- [ ] You: write release notes\n## Open questions\n- None yet"
    private let notesB = "## Summary\n- Beta ships Thursday\n## Decisions\n- Ship Thursday\n## Action items\n- [ ] You: write release notes\n## Open questions\n- None yet"

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
        let pending = await writer.pendingWords(in: MeetingTranscript(segments: [segment(0, .me, 0, 2, "Hello everyone.")]))
        XCTAssertEqual(pending, 2, "a failed update leaves the segment pending")
    }

    func testFinalPassRunsEvenWithNothingNew() async {
        let generator = FakeGenerator(replies: [notesA, notesB])
        let writer = MeetingNotesWriter(generator: generator)
        let transcript = MeetingTranscript(segments: [segment(0, .me, 0, 2, "Hello everyone.")])
        _ = await writer.update(with: transcript)
        let final = await writer.update(with: transcript, final: true)
        XCTAssertTrue(final)
        let requests = await generator.requests
        XCTAssertTrue(requests[1][1].content.contains("(no new speech)"))
        XCTAssertTrue(requests[1][1].content.contains("The meeting has ended"))
    }

    func testLongBacklogsAreSplitIntoBatches() {
        let long = Array(repeating: "word", count: 400).joined(separator: " ")
        let segments = (0..<3).map { segment($0, .others, Double($0 * 60), Double($0 * 60 + 50), long) }
        XCTAssertEqual(MeetingNotesWriter.batches(segments).map { $0.map(\.id) }, [[0, 1], [2]])
    }

    func testSanitizeStripsWrappers() {
        let wrapped = "<think>\nok\n</think>\nHere are the notes:\n```markdown\n\(notesA)\n```"
        XCTAssertEqual(MeetingNotesPrompt.sanitize(wrapped), notesA)
        XCTAssertNil(MeetingNotesPrompt.sanitize("## Summary\n- Only a summary"))
    }

    func testSchedule() {
        let schedule = MeetingNotesSchedule()
        XCTAssertFalse(schedule.isDue(pendingWords: 40, secondsSinceLastUpdate: 300))
        XCTAssertFalse(schedule.isDue(pendingWords: 100, secondsSinceLastUpdate: 20))
        XCTAssertTrue(schedule.isDue(pendingWords: 100, secondsSinceLastUpdate: 50))
        XCTAssertTrue(schedule.isDue(pendingWords: 400, secondsSinceLastUpdate: 5))
    }
}
