import AppKit
import MurmurCore

/// Watches the dictation key system-wide and feeds the hotkey state machine.
/// Needs Accessibility permission; without it macOS delivers no global key events.
final class HotkeyMonitor {
    var key: DictationKey {
        didSet { _ = machine.cancel(); keyIsDown = false }
    }
    var onAction: (HotkeyStateMachine.Action) -> Void = { _ in }
    var isRecording: Bool { machine.isRecording }

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
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) { monitors.append(local) }
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
            if event.keyCode == 53, machine.isRecording { dispatch(machine.cancel()) } // Escape
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
        timer = Timer.scheduledTimer(withTimeInterval: delay + 0.01, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.dispatch(self.machine.timeout(at: ProcessInfo.processInfo.systemUptime))
        }
    }
}
