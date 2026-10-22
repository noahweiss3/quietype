import XCTest

@testable import QuietypeCore

final class LiveTranscriptionTests: XCTestCase {
    /// Reports each segment's duration, so the joined text shows how audio was split.
    private actor FakeTranscriber: SpeechTranscriber {
        var calls = 0
        func transcribe(_ samples: [Float]) async throws -> String {
            calls += 1
            return "seg\(calls)(\(Int((Double(samples.count) / 16_000).rounded()))s)"
        }
    }

    private func tone(_ seconds: Double) -> [Float] { (0..<Int(seconds * 16_000)).map { 0.2 * sin(Float($0) * 0.1) } }
    private func silence(_ seconds: Double) -> [Float] { Array(repeating: 0, count: Int(seconds * 16_000)) }

    func testTranscribesClosedSegmentsThenTheTail() async throws {
        let fake = FakeTranscriber()
        let live = LiveTranscription(transcriber: fake)
        for chunk in [tone(5), silence(1), tone(3)] {
            for start in stride(from: 0, to: chunk.count, by: 4800) {
                await live.append(Array(chunk[start..<min(chunk.count, start + 4800)]))
            }
        }
        let result = try await live.finish()
        XCTAssertEqual(result.segments, 2)
        XCTAssertEqual(result.text, "seg1(5s) seg2(4s)")
        XCTAssertEqual(result.audioSeconds, 9, accuracy: 0.01)
    }

    func testSilentRecordingProducesNoText() async throws {
        let fake = FakeTranscriber()
        let live = LiveTranscription(transcriber: fake)
        await live.append(silence(2))
        let result = try await live.finish()
        XCTAssertEqual(result.text, "")
        let calls = await fake.calls
        XCTAssertEqual(calls, 0)
    }
}
