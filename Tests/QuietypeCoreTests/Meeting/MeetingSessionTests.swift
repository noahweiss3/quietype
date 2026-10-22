import XCTest

@testable import QuietypeCore

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
        let me = transcript.segments[0]
        let others = transcript.segments[1]
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
        let buffered = await session.bufferedSamples
        XCTAssertLessThanOrEqual(buffered, 21 * 16_000, "silence is cut and dropped every 20 s")
        let transcript = await session.finish()
        XCTAssertTrue(transcript.segments.isEmpty)
        let calls = await fake.calls
        XCTAssertEqual(calls, 0)
    }

    func testQuietCallAudioIsStillTranscribed() async {
        let fake = FakeTranscriber()
        let session = MeetingSession(transcriber: fake)
        await feed(session, tone(4, amplitude: 0.012), from: .others) // RMS about 0.0085
        let transcript = await session.finish()
        XCTAssertEqual(transcript.segments.count, 1)
    }

    func testPaddingLinesUpALateStream() async {
        let session = MeetingSession(transcriber: FakeTranscriber())
        await session.appendSilence(seconds: 1.5, to: .others)
        await feed(session, tone(4), from: .others)
        let transcript = await session.finish()
        XCTAssertEqual(transcript.segments.first?.start ?? 0, 1.3, accuracy: 0.05)
    }

    func testReportsEachNewSegment() async {
        let session = MeetingSession(transcriber: FakeTranscriber())
        let delivered = expectation(description: "both segment updates delivered")
        delivered.expectedFulfillmentCount = 2
        delivered.assertForOverFulfill = true
        let counter = Counter(delivered)
        await session.setOnUpdate { transcript in Task { await counter.record(transcript.segments.count) } }
        await feed(session, tone(4) + silence(1) + tone(4), from: .me)
        _ = await session.finish()
        await fulfillment(of: [delivered], timeout: 5)
        let seen = await counter.values
        XCTAssertEqual(seen.sorted(), [1, 2])
    }

    private actor Counter {
        var values: [Int] = []
        private let delivered: XCTestExpectation
        init(_ delivered: XCTestExpectation) { self.delivered = delivered }
        func record(_ value: Int) {
            values.append(value)
            delivered.fulfill()
        }
    }
}
