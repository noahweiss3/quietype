import XCTest

@testable import QuietypeCore

final class SpeechSegmenterTests: XCTestCase {
    private func tone(_ seconds: Double, amplitude: Float = 0.2) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amplitude * sin(Float($0) * 0.1) }
    }

    private func silence(_ seconds: Double) -> [Float] { Array(repeating: 0, count: Int(seconds * 16_000)) }

    func testCutsAtPausesAfterMinimumLength() {
        var segmenter = SpeechSegmenter(minPause: 0.5, minSegment: 4)
        var closed: [Range<Int>] = []
        // Short pause inside the first 4 s must not cut; the pause after 5 s should.
        for chunk in [tone(2), silence(0.6), tone(3), silence(0.8), tone(2)] {
            for slice in stride(from: 0, to: chunk.count, by: 1600) {
                closed += segmenter.append(Array(chunk[slice..<min(chunk.count, slice + 1600)]))
            }
        }
        XCTAssertEqual(closed.count, 1)
        let cutSeconds = Double(closed[0].upperBound) / 16_000
        XCTAssertGreaterThan(cutSeconds, 5.6)
        XCTAssertLessThan(cutSeconds, 6.4)
        XCTAssertEqual(segmenter.openSegmentStart, closed[0].upperBound)
    }

    func testSilenceIsNotSpeechButABurstAfterItIs() {
        XCTAssertFalse(SpeechSegmenter.containsSpeech(silence(1)))
        XCTAssertTrue(SpeechSegmenter.containsSpeech(silence(1) + tone(0.2)))
    }

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

    func testMeetingSegmenterClosesAShortPhraseAfterALongSilence() {
        var segmenter = SpeechSegmenter(minPause: 0.6, minSegment: 3, maxSegment: 20)
        var closed: [Range<Int>] = []
        for chunk in [tone(5), silence(0.7), tone(1.5), silence(3)] {
            closed += segmenter.append(chunk)
        }
        XCTAssertEqual(closed.count, 2)
        XCTAssertEqual(
            Double(closed[1].upperBound) / 16_000, 7.5, accuracy: 0.1, "cut in the long silence, not 18 s later")
    }

    func testDictationSegmenterNeverForcesACut() {
        var segmenter = SpeechSegmenter()
        XCTAssertEqual(segmenter.append(tone(45)), [])
    }
}
