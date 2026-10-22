import AppKit
import QuietypeCore

/// Watches the dictation key system-wide and feeds the hotkey state machine.
/// Needs Accessibility permission; without it macOS delivers no global key events.
@MainActor
final class HotkeyMonitor {
    private static let escapeKeyCode: UInt16 = 53

    var key: DictationKey {
        // Switching keys mid-recording must stop the recorder, not just forget about it.
        didSet {
            dispatch(machine.cancel())
            keyIsDown = false
        }
    }
    var onAction: (HotkeyStateMachine.Action) -> Void = { _ in }

    private var machine = HotkeyStateMachine()
    private var monitors: [Any] = []
    private var keyIsDown = false
    private var timer: Timer?

    init(key: DictationKey) {
        self.key = key
    }

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in self?.handle(event) }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
        monitors = [global, local].compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// Cancels whatever is in progress (used when recording can't start).
    func reset() {
        _ = machine.cancel()
        scheduleTimeout()
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.keyCode == Self.escapeKeyCode, machine.isRecording { dispatch(machine.cancel()) }
            return
        }
        guard event.keyCode == key.keyCode else { return }
        let down = event.modifierFlags.contains(key.flag)
        guard down != keyIsDown else { return }
        keyIsDown = down
        dispatch(down ? machine.keyDown(at: event.timestamp) : machine.keyUp(at: event.timestamp))
    }

    private func dispatch(_ actions: [HotkeyStateMachine.Action]) {
        actions.forEach(onAction)
        scheduleTimeout()
    }

    private func scheduleTimeout() {
        timer?.invalidate()
        timer = nil
        guard let deadline = machine.deadline else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        // Scheduled on the main run loop, so it fires on the main thread.
        timer = Timer.scheduledTimer(withTimeInterval: delay + 0.01, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dispatch(self.machine.timeout(at: ProcessInfo.processInfo.systemUptime))
            }
        }
    }
}
