import AppKit
import SwiftUI

/// What the floating pill at the bottom of the screen shows.
final class HUDModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case recording(handsFree: Bool)
        case processing
        case message(String)
    }

    @Published var phase: Phase = .hidden
    @Published var levels: [Float] = Array(repeating: 0, count: 14)

    func push(level: Float) {
        // Speech RMS sits around 0.01–0.2; map it to 0–1 on a log-ish curve.
        let scaled = min(1, max(0, (log10(max(level, 1e-4)) + 3.2) / 2.4))
        levels.removeFirst()
        levels.append(scaled)
    }
}

/// A non-activating floating panel, so showing it never steals focus from the app you're typing in.
final class RecordingHUD {
    let model = HUDModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
    }

    func show(_ phase: HUDModel.Phase) {
        hideWork?.cancel()
        model.phase = phase
        if phase == .hidden {
            panel.orderOut(nil)
            return
        }
        position()
        panel.orderFrontRegardless()
    }

    /// Shows a short message, then hides.
    func flash(_ message: String, seconds: Double = 2.5) {
        show(.message(message))
        let work = DispatchWorkItem { [weak self] in self?.show(.hidden) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 48))
    }
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .hidden:
                EmptyView()
            case let .recording(handsFree):
                Circle().fill(Color.red).frame(width: 8, height: 8)
                HStack(alignment: .center, spacing: 3) {
                    ForEach(Array(model.levels.enumerated()), id: \.offset) { _, level in
                        Capsule()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: 3, height: 4 + CGFloat(level) * 18)
                    }
                }
                .animation(.easeOut(duration: 0.08), value: model.levels)
                if handsFree {
                    Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.8))
                }
            case .processing:
                ProgressView().controlSize(.small).tint(.white)
                Text("Transcribing").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
            case let .message(text):
                Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
