import Foundation

/// Finds pauses in a live 16 kHz recording so finished stretches of speech can be transcribed
/// while the speaker is still talking. When the key is released only the last stretch is left.
public struct SpeechSegmenter: Sendable {
    public var sampleRate: Int
    /// A pause at least this long can end a segment.
    public var minPause: TimeInterval
    /// Segments shorter than this are not worth a separate transcription call.
    public var minSegment: TimeInterval
    /// RMS below this always counts as silence.
    public var silenceFloor: Float

    private let frameLength: Int
    private var samplesSeen = 0
    private var pending: [Float] = []
    private var segmentStart = 0
    private var silentFrames = 0
    private var silenceStart: Int?
    private var peak: Float = 0

    public init(sampleRate: Int = 16_000, minPause: TimeInterval = 0.5, minSegment: TimeInterval = 4, silenceFloor: Float = 0.004) {
        self.sampleRate = sampleRate
        self.minPause = minPause
        self.minSegment = minSegment
        self.silenceFloor = silenceFloor
        frameLength = sampleRate * 30 / 1000
    }

    /// Feeds new samples; returns segments (absolute sample ranges) that just closed.
    public mutating func append(_ samples: [Float]) -> [Range<Int>] {
        pending += samples
        var closed: [Range<Int>] = []
        let pauseFrames = Int(minPause * 1000 / 30)

        while pending.count >= frameLength {
            let frame = pending.prefix(frameLength)
            pending.removeFirst(frameLength)
            let frameStart = samplesSeen
            samplesSeen += frameLength

            let level = Self.rms(frame)
            peak = max(peak * 0.999, level)
            let silent = level < max(silenceFloor, peak * 0.08)

            if silent {
                if silenceStart == nil { silenceStart = frameStart }
                silentFrames += 1
            } else {
                silenceStart = nil
                silentFrames = 0
            }

            // Cut in the middle of a long enough pause, once the segment is long enough.
            if silentFrames >= pauseFrames, let pauseStart = silenceStart,
               Double(pauseStart - segmentStart) >= minSegment * Double(sampleRate) {
                let cut = pauseStart + (samplesSeen - pauseStart) / 2
                closed.append(segmentStart..<cut)
                segmentStart = cut
            }
        }
        return closed
    }

    /// Start of the segment that is still open.
    public var openSegmentStart: Int { segmentStart }

    public static func rms<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// True when any 30 ms frame is louder than `threshold`, i.e. there is something to transcribe.
    public static func containsSpeech(_ samples: [Float], sampleRate: Int = 16_000, threshold: Float = 0.01) -> Bool {
        let frame = max(1, sampleRate * 30 / 1000)
        var start = 0
        while start < samples.count {
            if rms(samples[start..<min(samples.count, start + frame)]) > threshold { return true }
            start += frame
        }
        return false
    }
}
