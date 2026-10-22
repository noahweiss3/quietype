import Foundation

@testable import QuietypeCore

/// A sine tone at 16 kHz, standing in for speech.
func tone(_ seconds: Double, amplitude: Float = 0.2) -> [Float] {
    (0..<Int(seconds * 16_000)).map { amplitude * sin(Float($0) * 0.1) }
}

/// Digital silence at 16 kHz.
func silence(_ seconds: Double) -> [Float] { Array(repeating: 0, count: Int(seconds * 16_000)) }

func segment(_ id: Int, _ speaker: MeetingSpeaker, _ start: Double, _ end: Double, _ text: String) -> MeetingSegment {
    MeetingSegment(id: id, speaker: speaker, start: start, end: end, text: text)
}
