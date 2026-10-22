import AVFoundation
import ScreenCaptureKit

/// Captures what the Mac is playing, which during a call is everyone else, as 16 kHz mono
/// samples. Uses ScreenCaptureKit, so macOS asks for Screen & System Audio Recording permission
/// the first time. Quietype's own sounds are excluded.
///
/// `@unchecked Sendable` is sound because the mutable state (`stream`, `continuation`, `resampler`)
/// is only touched on `queue`, the serial queue ScreenCaptureKit also delivers samples on.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "No display to capture audio from." }
    }

    private var stream: SCStream?
    private var continuation: AsyncStream<[Float]>.Continuation?
    private let queue = DispatchQueue(label: "quietype.system-audio")
    private let resampler = Resampler()

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
        queue.sync { self.continuation = continuation }
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
            queue.sync { self.continuation = nil }
            throw error
        }
        queue.sync { self.stream = stream }
        return samples
    }

    func stop() async {
        let stream = queue.sync { () -> SCStream? in
            defer { self.stream = nil }
            return self.stream
        }
        try? await stream?.stopCapture()
        queue.sync {
            continuation?.finish()
            continuation = nil
            resampler.reset()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let continuation else { return }
        guard let description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
            let format = AVAudioFormat(
                standardFormatWithSampleRate: description.mSampleRate, channels: description.mChannelsPerFrame)
        else { return }

        try? sampleBuffer.withAudioBufferList { bufferList, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: bufferList.unsafePointer),
                let samples = resampler.convert(buffer)
            else { return }
            continuation.yield(samples)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            self.continuation?.finish()
            self.continuation = nil
        }
    }
}
