import XCTest

@testable import QuietypeCore

final class LiveTranscriptionCancelTests: XCTestCase {
    /// Takes ten seconds per segment unless cancelled, and counts both.
    private actor SlowTranscriber: SpeechTranscriber {
        private(set) var started = 0
        private(set) var cancelled = 0

        func transcribe(_ samples: [Float]) async throws -> String {
            started += 1
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                cancelled += 1
                throw error
            }
            return "slow"
        }
    }

    private struct InstantTranscriber: SpeechTranscriber {
        func transcribe(_ samples: [Float]) async throws -> String { "word" }
    }

    private func feed(_ live: LiveTranscription, _ audio: [Float]) async {
        for start in stride(from: 0, to: audio.count, by: 4800) {
            await live.append(Array(audio[start..<min(audio.count, start + 4800)]))
        }
    }

    /// Three stretches, each ended by a pause, so three segments close.
    private var threeStretches: [Float] { (0..<3).flatMap { _ in tone(5) + silence(1) } }

    func testCancelSkipsQueuedSegmentsAndStopsTheOneInFlight() async throws {
        let slow = SlowTranscriber()
        let live = LiveTranscription(transcriber: slow)
        await feed(live, threeStretches)

        let deadline = Date().addingTimeInterval(5)
        while await slow.started == 0, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let startedBeforeCancel = await slow.started
        XCTAssertEqual(startedBeforeCancel, 1)

        await live.cancel()
        let finishStarted = Date()
        do {
            _ = try await live.finish()
            XCTFail("finish() should throw after cancel()")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(finishStarted), 5, "the in-flight segment wasn't cancelled")

        let started = await slow.started
        let cancelled = await slow.cancelled
        XCTAssertEqual(started, 1, "a queued segment started after cancel()")
        XCTAssertEqual(cancelled, 1)
    }

    func testCancelReleasesBufferedAudioAndIgnoresLaterAudio() async {
        let live = LiveTranscription(transcriber: InstantTranscriber())
        await live.append(tone(2))
        let buffered = await live.bufferedSamples
        XCTAssertEqual(buffered, 32_000)

        await live.cancel()
        let afterCancel = await live.bufferedSamples
        XCTAssertEqual(afterCancel, 0)
        await live.append(tone(1))
        let afterAppend = await live.bufferedSamples
        XCTAssertEqual(afterAppend, 0)
    }

    func testTranscribedAudioIsDroppedFromTheBuffer() async throws {
        let live = LiveTranscription(transcriber: InstantTranscriber())
        // A minute of hands-free dictation, with a pause every six seconds.
        for _ in 0..<10 { await feed(live, tone(5) + silence(1)) }

        // Only audio after the last cut (part of the final pause) is still held.
        let buffered = await live.bufferedSamples
        XCTAssertLessThan(buffered, 16_000)

        let result = try await live.finish()
        XCTAssertEqual(result.audioSeconds, 60, accuracy: 0.01)
        XCTAssertEqual(result.text, Array(repeating: "word", count: 10).joined(separator: " "))
    }
}
