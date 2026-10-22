import QuietypeCore
import QuietypeKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: AppController

    var body: some View {
        TabView {
            GeneralTab(settings: settings, controller: controller, cleanup: controller.cleanup)
                .tabItem { Label("General", systemImage: "gearshape") }
            DictionaryTab(settings: settings)
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            SnippetsTab(settings: settings)
                .tabItem { Label("Snippets", systemImage: "text.badge.plus") }
            HistoryTab(settings: settings, controller: controller)
                .tabItem { Label("History", systemImage: "clock") }
        }
        .padding(16)
        .frame(width: 560, height: 520)
    }
}

private struct GeneralTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: AppController
    @ObservedObject var cleanup: CleanupModelLoader
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    /// Set while the toggle is put back after a failure, so that change isn't applied again.
    @State private var revertingLaunchAtLogin = false

    var body: some View {
        Form {
            Section("Permissions") {
                PermissionRow(
                    title: "Microphone",
                    granted: controller.microphoneGranted,
                    action: { Task { await controller.requestMicrophone() } }
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
                        if revertingLaunchAtLogin {
                            revertingLaunchAtLogin = false
                            return
                        }
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            launchAtLoginError = nil
                        } catch {
                            launchAtLoginError = """
                                Couldn't \(enabled ? "turn on" : "turn off") launch at login: \
                                \(error.localizedDescription) You can change it in System Settings › General › \
                                Login Items.
                                """
                            let actual = SMAppService.mainApp.status == .enabled
                            if actual != enabled {
                                revertingLaunchAtLogin = true
                                launchAtLogin = actual
                            }
                        }
                    }
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.caption).foregroundStyle(.orange).fixedSize(
                        horizontal: false, vertical: true)
                }
            }

            Section("Speech recognition") {
                Picker("Model", selection: $settings.speechModel) {
                    ForEach(ParakeetTranscriber.Variant.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                StatusRow(state: controller.speechState)
                if controller.speechState.isFailed {
                    HStack {
                        Spacer()
                        Button("Retry") { Task { await controller.loadSpeechModel() } }
                    }
                }
            }

            Section("Cleanup") {
                Picker("Mode", selection: $settings.cleanupMode) {
                    ForEach(CleanupMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                // Shown in rules-only mode too, since meeting notes still need the model.
                Picker("Model", selection: $settings.cleanupModelID) {
                    ForEach(CleanupModel.all) { Text($0.name).tag($0.id) }
                }
                Text(
                    settings.cleanupMode == .rulesOnly
                        ? "Used only for meeting notes in this mode. \(settings.cleanupModel.detail)"
                        : settings.cleanupModel.detail
                )
                .font(.caption).foregroundStyle(.secondary)
                if cleanup.isDownloaded || cleanup.state.isDownloading {
                    StatusRow(state: cleanup.state)
                    if cleanup.state.isFailed {
                        HStack {
                            Spacer()
                            Button("Retry Loading") { cleanup.retryLoad() }
                            Button("Download Again") { cleanup.download(replacing: true) }
                        }
                        Text("A new download replaces the model only once its checksum matches.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if case let .downloadFailed(message) = cleanup.state {
                    HStack {
                        Text("Download failed: \(message)")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Retry") { cleanup.download() }
                    }
                } else {
                    Button("Download \(settings.cleanupModel.name)") { cleanup.download() }
                }
                if settings.cleanupMode != .rulesOnly {
                    Toggle("Speculative decoding (faster, same output)", isOn: $settings.speculativeDecoding)
                    if settings.speculativeDecoding, cleanup.speculationPaysOff == false {
                        Text("Inactive on this Mac: checking draft tokens in a batch costs more here than it saves.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            controller.refreshPermissions()
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
    var state: ModelState

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
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Names and terms Quietype should spell your way. One per line.")
            Text(
                """
                “Kubernetes” fixes spelling and casing. “cooper netties -> Kubernetes” replaces what the \
                transcriber heard.
                """
            )
            .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $settings.dictionaryText)
                .font(.system(.body, design: .monospaced))
                .border(Color.secondary.opacity(0.3))
        }
    }
}

private struct SnippetsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Say a trigger phrase and Quietype types the text instead.")
            Text(
                """
                Triggers work anywhere in a dictation and ignore case, punctuation and spacing. They match whole \
                words, so pick phrases you won't say otherwise: “my LinkedIn link” rather than “address”.
                """
            )
            .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(settings.snippets) { snippet in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("Trigger, e.g. my LinkedIn", text: binding(snippet.id, \.trigger))
                            Button {
                                settings.snippets.removeAll { $0.id == snippet.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete snippet")
                        }
                        TextEditor(text: binding(snippet.id, \.text))
                            .font(.system(.body, design: .monospaced))
                            .frame(height: snippet.text.contains("\n") ? 72 : 36)
                            .border(Color.secondary.opacity(0.3))
                        if let clash = clash(for: snippet) {
                            Text(clash).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            HStack {
                Button("Add Snippet") { settings.snippets.append(Snippet(trigger: "", text: "")) }
                Spacer()
                Text("Expanded text is pasted exactly as written.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Bindings by id rather than index, so deleting a row never points a field at the wrong snippet.
    private func binding(_ id: UUID, _ field: WritableKeyPath<Snippet, String>) -> Binding<String> {
        Binding(
            get: { settings.snippets.first { $0.id == id }?[keyPath: field] ?? "" },
            set: { value in
                guard let index = settings.snippets.firstIndex(where: { $0.id == id }) else { return }
                settings.snippets[index][keyPath: field] = value
            }
        )
    }

    private func clash(for snippet: Snippet) -> String? {
        guard !snippet.key.isEmpty,
            settings.snippets.contains(where: { $0.id != snippet.id && $0.key == snippet.key })
        else { return nil }
        return "Another snippet has the same trigger; only one of them will be used."
    }
}

private struct HistoryTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading) {
            Toggle("Keep history", isOn: $settings.keepHistory)
            Text(
                settings.keepHistory
                    ? "Your last 100 dictations are saved on this Mac as plain text."
                    : "New dictations aren't saved. Entries already here stay until you clear them."
            )
            .font(.caption).foregroundStyle(.secondary)
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
            if let error = controller.historyError {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                // An unreadable history leaves the list empty but a kept copy on disk to clear.
                Button("Clear History") { controller.clearHistory() }
                    .disabled(controller.history.isEmpty && controller.historyError == nil)
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
        parts.append(entry.result.path.displayName)
        if let snippets = entry.result.snippets { parts.append("snippets: " + snippets.joined(separator: ", ")) }
        if let note = entry.result.note { parts.append(note) }
        return parts.joined(separator: " · ")
    }
}
