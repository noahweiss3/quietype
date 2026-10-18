import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings()
    private lazy var controller = AppController(settings: settings)
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var meetingWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon(recording: false, meeting: false)
        controller.$isRecording.sink { [weak self] recording in
            guard let self else { return }
            self.updateIcon(recording: recording, meeting: self.controller.meeting.isActive)
        }.store(in: &cancellables)
        controller.meeting.$state.sink { [weak self] state in
            guard let self else { return }
            self.updateIcon(recording: self.controller.isRecording, meeting: state == .recording || state == .finishing)
        }.store(in: &cancellables)

        controller.start()
        if !settings.hasCompletedSetup || !Permissions.accessibilityGranted { showSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.meeting.saveNow()
    }

    private func updateIcon(recording: Bool, meeting: Bool) {
        let name = meeting ? "record.circle" : recording ? "waveform.circle.fill" : "waveform"
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Murmur")
        statusItem.button?.contentTintColor = recording || meeting ? .systemRed : nil
    }

    // Rebuilt every time it opens, so status and history are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let key = settings.dictationKey.displayName
        menu.addItem(disabled("Hold \(key) to dictate, double-tap for hands-free"))
        menu.addItem(disabled("Speech: \(controller.speechState.summary)"))
        let cleanup = settings.cleanupMode == .rulesOnly ? "Off" : controller.cleanupModelDownloaded || controller.cleanupState.isDownloading
            ? controller.cleanupState.summary : "Model not downloaded"
        menu.addItem(disabled("Cleanup: \(cleanup)"))
        if !controller.accessibilityGranted {
            menu.addItem(item("Grant Accessibility Access…") { Permissions.promptForAccessibility() })
        }
        menu.addItem(.separator())

        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for entry in controller.history.prefix(10) {
            let text = entry.result.text.replacingOccurrences(of: "\n", with: " ")
            let title = text.count > 60 ? String(text.prefix(60)) + "…" : text
            let row = item(title) { Paster.copy(entry.result.text) }
            row.toolTip = "Click to copy. \(String(format: "%.2f", entry.totalSeconds))s after release, \(entry.result.path.rawValue)"
            submenu.addItem(row)
        }
        if controller.history.isEmpty { submenu.addItem(disabled("Nothing yet")) }
        recent.submenu = submenu
        menu.addItem(recent)
        menu.addItem(item("Paste Last Dictation") { [weak self] in self?.controller.pasteLast() })
        menu.addItem(.separator())
        switch controller.meeting.state {
        case .starting, .recording:
            menu.addItem(item("Stop Meeting Notes") { [weak self] in Task { await self?.controller.meeting.stop() } })
            menu.addItem(item("Show Meeting Notes…") { [weak self] in self?.showMeeting() })
        case .finishing:
            menu.addItem(disabled("Finishing Meeting Notes…"))
            menu.addItem(item("Show Meeting Notes…") { [weak self] in self?.showMeeting() })
        case .idle, .finished:
            menu.addItem(item("Start Meeting Notes") { [weak self] in
                self?.showMeeting()
                Task { await self?.controller.meeting.start() }
            })
            if meetingWindow != nil { menu.addItem(item("Show Meeting Notes…") { [weak self] in self?.showMeeting() }) }
        }
        menu.addItem(.separator())
        menu.addItem(item("Settings…", key: ",") { [weak self] in self?.showSettings() })
        menu.addItem(item("Quit Murmur", key: "q") { NSApp.terminate(nil) })
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Murmur"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(settings: settings, controller: controller))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showMeeting() {
        if meetingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Meeting Notes"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MeetingView(meeting: controller.meeting))
            window.center()
            meetingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        meetingWindow?.makeKeyAndOrderFront(nil)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, key: String = "", action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, keyEquivalent: key, action: action)
        return item
    }
}

/// NSMenuItem that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
