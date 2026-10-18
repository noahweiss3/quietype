import Foundation
import MurmurCore

// Thin JSON front end over MurmurCore so the cleanup prompt can be evaluated against any
// llama.cpp server (see evals/run_evals.py) using exactly the code the app runs.
//
//   murmur-cli rules "um so the the plan is"     rules pass only
//   murmur-cli prep  < cases.jsonl                rules + LLM messages per case
//   murmur-cli finish < results.jsonl             guard, fallback and dictionary per case
//   murmur-cli notes-plan / notes-prep / notes-finish   live meeting notes (evals/run_meeting_notes.py)

let usage = """
usage:
  murmur-cli rules <text>
  murmur-cli prep    reads JSONL {"id","input","style"?,"vocabulary"?}, writes {"id","rules_text","cues","needs_llm","messages"}
  murmur-cli finish  reads JSONL {"id","input","llm_output"?,"style"?,"vocabulary"?,"mode"?,"snippets"?}, writes {"id","result"}
  murmur-cli notes-plan    reads JSONL {"id","segments"}, writes {"id","updates":[{"at","segments","final","complete"}]}
  murmur-cli notes-prep    reads JSONL {"id","notes","segments","final","complete"?,"known"?,"retry"?}, writes {"id","messages","max_tokens"}
  murmur-cli notes-finish  reads JSONL {"id","previous","output"}, writes {"id","notes","accepted"}
"""

struct PrepCase: Decodable {
    var id: String
    var input: String
    var style: WritingStyle?
    var vocabulary: [String]?
}

struct PrepOutput: Encodable {
    var id: String
    var rules_text: String
    var cues: [String]
    var needs_llm: Bool
    var messages: [ChatMessage]
}

struct FinishCase: Decodable {
    var id: String
    var input: String
    var llm_output: String?
    var style: WritingStyle?
    var vocabulary: [String]?
    var mode: CleanupMode?
    var snippets: [SnippetSpec]?
}

struct SnippetSpec: Decodable {
    var trigger: String
    var text: String
}

struct FinishOutput: Encodable {
    var id: String
    var result: ProcessedDictation
}

struct NotesPlanCase: Decodable {
    var id: String
    var segments: [MeetingSegment]
}

struct NotesUpdate: Encodable {
    var at: Double
    var segments: [Int]
    var final: Bool
    var complete = false
}

struct NotesPlanOutput: Encodable {
    var id: String
    var updates: [NotesUpdate]
}

struct NotesPrepCase: Decodable {
    var id: String
    var notes: String
    var segments: [MeetingSegment]
    var final: Bool
    var complete: Bool?
    /// Everything said so far, for the names the app passes along.
    var known: [MeetingSegment]?
    /// The previous answer failed; ask again the way the app does.
    var retry: Bool?
}

struct NotesPrepOutput: Encodable {
    var id: String
    var messages: [ChatMessage]
    var max_tokens: Int
}

struct NotesFinishCase: Decodable {
    var id: String
    var previous: String
    var output: String
}

struct NotesFinishOutput: Encodable {
    var id: String
    var notes: String
    var accepted: Bool
}

/// Replays a meeting in real time: segments arrive when they end, and the notes update whenever
/// the app's schedule says so, in the same batches the app would send.
func planNotes(_ segments: [MeetingSegment], schedule: MeetingNotesSchedule = MeetingNotesSchedule()) -> [NotesUpdate] {
    var transcript = MeetingTranscript()
    var covered = Set<Int>()
    var lastUpdate = 0.0
    var updates: [NotesUpdate] = []
    func flush(at time: Double, final: Bool) {
        if final, MeetingNotesWriter.finalPassReadsEverything(transcript) {
            updates.append(NotesUpdate(at: time, segments: transcript.segments.map(\.id), final: true, complete: true))
            return
        }
        let pending = transcript.segments.filter { !covered.contains($0.id) }
        let batches = MeetingNotesWriter.batches(pending)
        for (index, batch) in batches.enumerated() {
            updates.append(NotesUpdate(at: time, segments: batch.map(\.id), final: final && index == batches.count - 1))
        }
        if batches.isEmpty, final { updates.append(NotesUpdate(at: time, segments: [], final: true)) }
        covered.formUnion(pending.map(\.id))
        lastUpdate = time
    }
    for segment in segments.sorted(by: { $0.end < $1.end }) {
        transcript.add(segment)
        let pendingWords = transcript.segments.filter { !covered.contains($0.id) }
            .reduce(0) { $0 + MeetingTranscript.wordCount($1.text) }
        if schedule.isDue(pendingWords: pendingWords, secondsSinceLastUpdate: segment.end - lastUpdate) {
            flush(at: segment.end, final: false)
        }
    }
    flush(at: segments.map(\.end).max() ?? 0, final: true)
    return updates
}

/// Replays an LLM answer that was produced elsewhere.
struct RecordedCleaner: TextCleaner {
    var output: String
    func clean(_ dictation: String, style: WritingStyle, vocabulary: [String]) async throws -> String { output }
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

func emit<T: Encodable>(_ value: T) {
    print(String(decoding: try! encoder.encode(value), as: UTF8.self))
}

func readLines<T: Decodable>(_ type: T.Type) -> [T] {
    var items: [T] = []
    while let line = readLine(), !line.isEmpty {
        do {
            items.append(try JSONDecoder().decode(T.self, from: Data(line.utf8)))
        } catch {
            FileHandle.standardError.write(Data("bad line: \(error)\n".utf8))
            exit(1)
        }
    }
    return items
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "rules":
    let result = Rules.apply(args.dropFirst().joined(separator: " "))
    emit(["text": result.text, "cues": result.cues.map(\.rawValue).sorted().joined(separator: ",")])

case "prep":
    for item in readLines(PrepCase.self) {
        let rules = Rules.apply(item.input)
        emit(PrepOutput(
            id: item.id,
            rules_text: rules.text,
            cues: rules.cues.map(\.rawValue).sorted(),
            needs_llm: rules.needsLLM,
            messages: CleanupPrompt.messages(dictation: rules.text, style: item.style ?? .standard, vocabulary: item.vocabulary ?? [])
        ))
    }

case "finish":
    let items = readLines(FinishCase.self)
    let done = DispatchSemaphore(value: 0)
    Task {
        for item in items {
            let processor = DictationProcessor(cleaner: item.llm_output.map { RecordedCleaner(output: $0) })
            let context = DictationContext(
                style: item.style ?? .standard,
                mode: item.mode ?? (item.llm_output == nil ? .rulesOnly : .always),
                dictionary: PersonalDictionary(terms: item.vocabulary ?? []),
                snippets: Snippets((item.snippets ?? []).map { Snippet(trigger: $0.trigger, text: $0.text) }),
                appendTrailingSpace: false
            )
            emit(FinishOutput(id: item.id, result: await processor.process(item.input, context: context)))
        }
        done.signal()
    }
    done.wait()

case "notes-plan":
    for item in readLines(NotesPlanCase.self) {
        emit(NotesPlanOutput(id: item.id, updates: planNotes(item.segments)))
    }

case "notes-prep":
    for item in readLines(NotesPrepCase.self) {
        emit(NotesPrepOutput(
            id: item.id,
            messages: MeetingNotesPrompt.request(
                notes: item.notes, segments: item.segments, known: item.known ?? item.segments,
                final: item.final, complete: item.complete ?? false, retry: item.retry ?? false
            ),
            max_tokens: MeetingNotesPrompt.maxOutputTokens
        ))
    }

case "notes-finish":
    for item in readLines(NotesFinishCase.self) {
        let cleaned = MeetingNotesPrompt.sanitize(item.output)
        emit(NotesFinishOutput(id: item.id, notes: cleaned ?? item.previous, accepted: cleaned != nil))
    }

default:
    print(usage)
    exit(args.isEmpty ? 0 : 1)
}
