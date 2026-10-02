import MurmurCore
import MurmurKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var controller: AppController

    var body: some View {
        TabView {
            SetupTab(settings: settings, controller: controller)
                .tabItem { Label("General", systemImage: "gearshape") }
            DictionaryTab(settings: settings)
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            HistoryTab(controller: controller)
                .tabItem { Label("History", systemImage: "clock") }
        }
        .padding(16)
        .frame(width: 560, height: 520)
    }
}

private struct SetupTab: View {
    @ObservedObject var settings: Settings
    @ObservedObject var controller: AppController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var microphoneGranted = Permissions.microphoneGranted

    var body: some View {
        Form {
            Section("Permissions") {
                PermissionRow(
                    title: "Microphone",
                    granted: microphoneGranted,
                    action: {
                        Task {
                            if Permissions.microphoneDenied { Permissions.openMicrophoneSettings() }
                            microphoneGranted = await Permissions.requestMicrophone()
                        }
                    }
                )
                PermissionRow(
                    title: "Accessibility (hotkey and pasting)",
                    granted: controller.accessibilityGranted,
                    action: {
                        Permissions.promptForAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                )
            }

            Section("Dictation") {
                Picker("Dictation key", selection: $settings.dictationKey) {
                    ForEach(DictationKey.allCases) { Text($0.displayName).tag($0) }
                }
                Text("Hold to talk. Double-tap for hands-free, then tap again to finish. Esc cancels.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.dictationKey == .fn {
                    Text("Set System Settings › Keyboard › “Press 🌐 key to” to “Do Nothing”.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("Add a space after each dictation", isOn: $settings.appendTrailingSpace)
                Toggle("Play sounds", isOn: $settings.playSounds)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("Speech recognition") {
                Picker("Model", selection: $settings.speechModel) {
                    ForEach(ParakeetTranscriber.Variant.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                StatusRow(state: controller.speechState)
            }

            Section("Cleanup") {
                Picker("Mode", selection: $settings.cleanupMode) {
                    ForEach(CleanupMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                if settings.cleanupMode != .rulesOnly {
                    Picker("Model", selection: $settings.cleanupModelID) {
                        ForEach(CleanupModel.all) { Text($0.name).tag($0.id) }
                    }
                    Text(settings.cleanupModel.detail).font(.caption).foregroundStyle(.secondary)
                    if controller.cleanupModelDownloaded || controller.cleanupState.isDownloading {
                        StatusRow(state: controller.cleanupState)
                    } else {
                        Button("Download \(settings.cleanupModel.name)") { controller.downloadCleanupModel() }
                    }
                    Toggle("Speculative decoding (faster, same output)", isOn: $settings.speculativeDecoding)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            microphoneGranted = Permissions.microphoneGranted
            settings.hasCompletedSetup = true
        }
    }
}

private struct PermissionRow: View {
    var title: String
    var granted: Bool
    var action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(title)
            Spacer()
            if !granted { Button("Grant…", action: action) }
        }
    }
}

private struct StatusRow: View {
    var state: AppController.ModelState

    var body: some View {
        HStack {
            Text("Status")
            Spacer()
            if case let .downloading(fraction) = state {
                ProgressView(value: fraction).frame(width: 140)
            }
            Text(state.summary)
                .foregroundStyle(state == .ready ? .green : .secondary)
                .lineLimit(2)
        }
    }
}

private struct DictionaryTab: View {
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Names and terms Murmur should spell your way. One per line.")
            Text("“Kubernetes” fixes spelling and casing. “cooper netties -> Kubernetes” replaces what the transcriber heard.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $settings.dictionaryText)
                .font(.system(.body, design: .monospaced))
                .border(Color.secondary.opacity(0.3))
        }
    }
}

private struct HistoryTab: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading) {
            if controller.history.isEmpty {
                Spacer()
                Text("No dictations yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(controller.history) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.result.text).textSelection(.enabled)
                        if entry.result.raw != entry.result.text {
                            Text(entry.result.raw).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Text(timing(entry)).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("Copy") { Paster.copy(entry.result.text) }
                        Button("Copy Raw Transcript") { Paster.copy(entry.result.raw) }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Clear History") { controller.clearHistory() }.disabled(controller.history.isEmpty)
            }
        }
    }

    private func timing(_ entry: HistoryEntry) -> String {
        var parts = [
            String(format: "%.1fs audio", entry.audioSeconds),
            String(format: "%.0f ms transcribe", entry.transcribeSeconds * 1000),
        ]
        if let llm = entry.result.llmSeconds { parts.append(String(format: "%.0f ms cleanup", llm * 1000)) }
        parts.append(String(format: "%.0f ms total", entry.totalSeconds * 1000))
        parts.append(entry.result.path.rawValue)
        if let note = entry.result.note { parts.append(note) }
        return parts.joined(separator: " · ")
    }
}
