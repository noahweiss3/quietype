import AVFoundation
import ScreenCaptureKit

/// Captures what the Mac is playing, which during a call is everyone else, as 16 kHz mono
/// samples. Uses ScreenCaptureKit, so macOS asks for Screen & System Audio Recording permission
/// the first time. Murmur's own sounds are excluded.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "No display to capture audio from." }
    }

    private var stream: SCStream?
    private var continuation: AsyncStream<[Float]>.Continuation?
    private let queue = DispatchQueue(label: "murmur.system-audio")
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?

    /// Starts capturing. Samples arrive on the returned stream until `stop()`.
    func start() async throws -> AsyncStream<[Float]> {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // Video can't be switched off, so ask for as little of it as possible.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let (samples, continuation) = AsyncStream<[Float]>.makeStream()
        self.continuation = continuation
        let stream = SCStream(
            filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []),
            configuration: configuration,
            delegate: self
        )
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            // Without a screen output ScreenCaptureKit logs every dropped video frame.
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            continuation.finish()
            self.continuation = nil
            throw error
        }
        self.stream = stream
        return samples
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        queue.sync {
            continuation?.finish()
            continuation = nil
            converter = nil
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let continuation else { return }
        guard let description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(standardFormatWithSampleRate: description.mSampleRate, channels: description.mChannelsPerFrame)
        else { return }

        try? sampleBuffer.withAudioBufferList { bufferList, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: bufferList.unsafePointer),
                  let samples = convert(buffer) else { return }
            continuation.yield(samples)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            self.continuation?.finish()
            self.continuation = nil
        }
    }

    /// Downmixes and resamples to 16 kHz mono.
    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.downmix = true
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0], output.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
