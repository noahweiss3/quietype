import AVFoundation

/// Converts audio buffers of any format to 16 kHz mono Float32, which is what the speech model
/// takes. The converter is kept between buffers so the resampling filter runs on across their edges.
final class Resampler {
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private var converter: AVAudioConverter?

    /// Forgets the converter, so the next buffer starts a fresh stream.
    func reset() {
        converter = nil
    }

    /// Downmixes and resamples one buffer. Returns nil if it can't be converted.
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        // Covers both the first buffer and an input whose format changed mid-stream.
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.format)
            converter?.downmix = true
        }
        guard let converter else { return nil }
        let capacity =
            AVAudioFrameCount(Double(buffer.frameLength) * Self.format.sampleRate / buffer.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return nil }

        // Hand the converter this one buffer, then tell it there is nothing more for now. The block
        // is `@Sendable`, but the converter only calls it synchronously, inside `convert`.
        nonisolated(unsafe) var delivered = false
        nonisolated(unsafe) let input = buffer
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let channel = output.floatChannelData?[0], output.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
