import MurmurCore
import SwiftUI

/// Live transcript on the left, notes that keep updating on the right.
struct MeetingView: View {
    @ObservedObject var meeting: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let warning = meeting.warning {
                Text(warning).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HSplitView {
                transcriptPane.frame(minWidth: 280)
                notesPane.frame(minWidth: 260)
            }
        }
        .padding(14)
        .frame(minWidth: 720, minHeight: 460)
    }

    private var header: some View {
        HStack(spacing: 10) {
            switch meeting.state {
            case .idle:
                Text("Murmur transcribes your mic and the call's audio on this Mac and keeps notes as you talk.")
                    .foregroundStyle(.secondary)
            case .starting:
                ProgressView().controlSize(.small)
                Text("Starting…")
            case .recording:
                Circle().fill(.red).frame(width: 9, height: 9)
                if let startedAt = meeting.startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text("Recording \(MeetingTranscript.timestamp(context.date.timeIntervalSince(startedAt)))")
                            .monospacedDigit()
                    }
                }
            case .finishing:
                ProgressView().controlSize(.small)
                Text("Finishing transcript and notes…")
            case .finished:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Saved")
            }
            Spacer()
            if meeting.state == .finished {
                Button("Show in Finder") { meeting.showInFinder() }.disabled(meeting.savedFile == nil)
            }
            if meeting.state == .recording || meeting.state == .finished {
                Button("Copy Notes & Transcript") { meeting.copyNotes() }
            }
            if meeting.state == .recording {
                Button("Stop") { Task { await meeting.stop() } }.keyboardShortcut(".", modifiers: .command)
            } else {
                Button(meeting.state == .finished ? "New Meeting" : "Start") { Task { await meeting.start() } }
                    .disabled(meeting.isActive)
            }
        }
    }

    private var transcriptPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Transcript").font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(meeting.transcript.segments) { segment in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(MeetingTranscript.timestamp(segment.start))
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                Text(segment.speaker.label)
                                    .font(.caption.bold())
                                    .foregroundStyle(segment.speaker == .me ? Color.accentColor : Color.purple)
                                    .frame(width: 44, alignment: .leading)
                                Text(segment.text).textSelection(.enabled)
                            }
                            .id(segment.id)
                        }
                        if meeting.transcript.segments.isEmpty, meeting.state == .recording {
                            Text("Listening…").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.trailing, 8)
                }
                .onChange(of: meeting.transcript.segments.last?.id) { _, last in
                    if let last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
                }
            }
        }
        .padding(.trailing, 8)
    }

    private var notesPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Notes").font(.headline)
                if meeting.isUpdatingNotes {
                    ProgressView().controlSize(.mini)
                    Text("Updating…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = meeting.notesError {
                Text("The last notes update didn't work and will be retried: \(error)")
                    .font(.caption).foregroundStyle(.orange).lineLimit(3)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if meeting.notes.isEmpty {
                        Text(meeting.state == .recording ? "Notes appear after the first minute or so of talking." : "No notes yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(meeting.notes.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                        NotesLine(line: String(line))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        }
        .padding(.leading, 8)
    }
}

/// One line of the notes' Markdown, drawn without a Markdown renderer.
private struct NotesLine: View {
    var line: String

    var body: some View {
        if line.hasPrefix("## ") {
            Text(line.dropFirst(3)).font(.subheadline.bold()).padding(.top, 6)
        } else if line.hasPrefix("- [ ] ") {
            Label(String(line.dropFirst(6)), systemImage: "square").labelStyle(BulletStyle())
        } else if line.hasPrefix("- ") {
            Label(String(line.dropFirst(2)), systemImage: "circle.fill").labelStyle(BulletStyle(small: true))
        } else {
            Text(line)
        }
    }
}

private struct BulletStyle: LabelStyle {
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.font(.system(size: small ? 4 : 10)).foregroundStyle(.secondary)
            configuration.title
        }
    }
}
