import Foundation
import QuietypeCore

// A JSON-lines front end over QuietypeCore, so the evals (evals/README.md) run the app's own rules,
// prompts, output guard and meeting-notes writer against a llama.cpp server. Only the model call
// happens outside this binary.

let usage = """
    usage: quietype-cli <command>

      rules <text>   Run the rules pass on <text> and print the result.

    The other commands read one JSON object per line on stdin and write one per line on stdout.

      prep           {"id", "input", "style"?, "vocabulary"?, "snippets"?}
                     -> {"id", "rules_text", "cues", "needs_llm", "messages", "content_marker"}
                     The rules pass, and the cleanup request the app would send to the LLM.
                     content_marker is where the runner splits the rendered chat template into
                     the prefix it caches and the per-dictation suffix.

      budget         {"id", "input_tokens"}
                     -> {"id", "max_tokens"}
                     The app's output limit for a cleanup request. input_tokens counts the part the
                     app evaluates per dictation: the last message's content followed by the chat
                     template's closing and assistant header.

      finish         {"id", "input", "llm_output"?, "style"?, "vocabulary"?, "mode"?, "snippets"?}
                     -> {"id", "result"}
                     Output guard, rules-only fallback, dictionary and snippets, as the app runs them.

      notes-replay   Replays one meeting through the app's notes writer. The first line is
                     {"id", "segments"}. For every request the writer makes, it prints
                     {"event": "generate", "messages", "max_tokens", "context_tokens"} and reads
                     {"output"} or {"error"} back on stdin. It prints {"event": "update", ...} after
                     each notes update and {"event": "done", ...} at the end.
    """

// MARK: Cleanup

// The JSON keys are snake_case, as the eval scripts expect. They're spelled out in CodingKeys
// rather than left to a key strategy, which would also rename the camelCase keys of library types
// such as ProcessedDictation.

struct PrepCase: Decodable {
    var id: String
    var input: String
    var style: WritingStyle?
    var vocabulary: [String]?
    var snippets: [SnippetSpec]?
}

struct PrepOutput: Encodable {
    var id: String
    var rulesText: String
    var cues: [String]
    var needsLLM: Bool
    var messages: [ChatMessage]
    var contentMarker = CleanupPrompt.contentMarker

    enum CodingKeys: String, CodingKey {
        case id, cues, messages
        case rulesText = "rules_text"
        case needsLLM = "needs_llm"
        case contentMarker = "content_marker"
    }
}

struct BudgetCase: Decodable {
    var id: String
    var inputTokens: Int

    enum CodingKeys: String, CodingKey {
        case id
        case inputTokens = "input_tokens"
    }
}

struct BudgetOutput: Encodable {
    var id: String
    var maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case id
        case maxTokens = "max_tokens"
    }
}

struct FinishCase: Decodable {
    var id: String
    var input: String
    var llmOutput: String?
    var style: WritingStyle?
    var vocabulary: [String]?
    var mode: CleanupMode?
    var snippets: [SnippetSpec]?

    enum CodingKeys: String, CodingKey {
        case id, input, style, vocabulary, mode, snippets
        case llmOutput = "llm_output"
    }
}

struct SnippetSpec: Decodable {
    var trigger: String
    var text: String
}

struct FinishOutput: Encodable {
    var id: String
    var result: ProcessedDictation
}

/// Replays an LLM answer that was produced elsewhere.
struct RecordedCleaner: TextCleaner {
    var output: String
    func clean(_ dictation: String, style: WritingStyle, vocabulary: [String]) async throws -> String { output }
}

func snippets(_ specs: [SnippetSpec]?) -> Snippets {
    Snippets((specs ?? []).map { Snippet(trigger: $0.trigger, text: $0.text) })
}

// MARK: Meeting notes

struct ReplayInput: Decodable {
    var id: String
    var segments: [MeetingSegment]
}

struct GenerateRequest: Encodable {
    var event = "generate"
    var messages: [ChatMessage]
    var maxTokens: Int
    var contextTokens: Int

    enum CodingKeys: String, CodingKey {
        case event, messages
        case maxTokens = "max_tokens"
        case contextTokens = "context_tokens"
    }
}

struct GenerateReply: Decodable {
    var output: String?
    var error: String?
}

struct UpdateEvent: Encodable {
    var event = "update"
    /// Seconds into the meeting.
    var at: Double
    var final: Bool
    var ok: Bool
    var notes: String
    var error: String?
    /// Words said so far that the notes don't cover yet.
    var pendingWords: Int

    enum CodingKeys: String, CodingKey {
        case event, at, final, ok, notes, error
        case pendingWords = "pending_words"
    }
}

struct DoneEvent: Encodable {
    var event = "done"
    var id: String
    var notes: String
    var updates: Int
}

/// The answer the driving process got from the model, or the reason it has none. Errors read like
/// the app's own (an answer cut off at the limit, a prompt too long for the context), and the
/// writer handles them the same way.
struct ReplayGenerator: TextGenerator {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    func generate(_ messages: [ChatMessage], maxTokens: Int) async throws -> String {
        emit(GenerateRequest(messages: messages, maxTokens: maxTokens, contextTokens: MeetingNotesPrompt.contextTokens))
        guard let line = readLine() else { fail("notes-replay: stdin closed while waiting for a model answer") }
        let reply: GenerateReply
        do {
            reply = try JSONDecoder().decode(GenerateReply.self, from: Data(line.utf8))
        } catch {
            fail("notes-replay: bad reply: \(error)")
        }
        if let error = reply.error { throw Failure(description: error) }
        guard let output = reply.output else { fail("notes-replay: a reply needs \"output\" or \"error\"") }
        return output
    }
}

/// Drives the notes writer the way MeetingController does during a meeting: every
/// `MeetingNotesSchedule.tickInterval` seconds it asks the schedule whether the notes are due,
/// counting failed updates in a row as the controller does. When the meeting ends, the writer
/// gets the whole transcript for its final pass. Segments count as heard once they end, and each
/// update counts as instant, so a tick is never skipped because an update is still running.
func replay(_ meeting: ReplayInput) async {
    let writer = MeetingNotesWriter(generator: ReplayGenerator())
    let schedule = MeetingNotesSchedule()
    let ordered = meeting.segments.sorted { $0.end < $1.end }
    let end = ordered.last?.end ?? 0
    var transcript = MeetingTranscript()
    var heard = 0
    var lastUpdate = 0.0
    var failures = 0

    func report(at time: Double, final: Bool, ok: Bool) async {
        let notes = await writer.notes
        let error = await writer.lastError
        let pending = await writer.pendingWords(in: transcript)
        emit(UpdateEvent(at: time, final: final, ok: ok, notes: notes, error: ok ? nil : error, pendingWords: pending))
    }

    var tick = MeetingNotesSchedule.tickInterval
    while tick < end {
        while heard < ordered.count, ordered[heard].end <= tick {
            transcript.add(ordered[heard])
            heard += 1
        }
        let pending = await writer.pendingWords(in: transcript)
        if schedule.isDue(pendingWords: pending, secondsSinceLastUpdate: tick - lastUpdate, failures: failures) {
            lastUpdate = tick
            let ok = await writer.update(with: transcript)
            failures = await writer.lastError == nil ? 0 : failures + 1
            await report(at: tick, final: false, ok: ok)
        }
        tick += MeetingNotesSchedule.tickInterval
    }

    for segment in ordered[heard...] { transcript.add(segment) }
    let ok = await writer.update(with: transcript, final: true)
    await report(at: end, final: true, ok: ok)
    emit(DoneEvent(id: meeting.id, notes: await writer.notes, updates: await writer.updates))
}

// MARK: I/O

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

/// Writes one JSON line and flushes, so a process reading the other end of a pipe sees it now.
func emit<T: Encodable>(_ value: T) {
    print(String(decoding: try! encoder.encode(value), as: UTF8.self))
    // Flushes every output stream: Glibc declares `stdout` as a mutable global, which Swift 6 won't read.
    fflush(nil)
}

/// Exits 2, like the eval scripts do when the harness rather than a case fails.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func decodeLine<T: Decodable>(_ line: String, as type: T.Type) -> T {
    do {
        return try JSONDecoder().decode(T.self, from: Data(line.utf8))
    } catch {
        fail("bad line: \(error)\n  \(line.prefix(200))")
    }
}

func readLines<T: Decodable>(_ type: T.Type) -> [T] {
    var items: [T] = []
    while let line = readLine() {
        if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        items.append(decodeLine(line, as: T.self))
    }
    return items
}

/// Runs async work from this synchronous entry point.
func runAsync(_ work: @escaping @Sendable () async -> Void) {
    let done = DispatchSemaphore(value: 0)
    Task {
        await work()
        done.signal()
    }
    done.wait()
}

// MARK: Commands

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "rules":
    let result = Rules.apply(args.dropFirst().joined(separator: " "))
    emit(["text": result.text, "cues": result.cues.map(\.rawValue).sorted().joined(separator: ",")])

case "prep":
    for item in readLines(PrepCase.self) {
        let rules = Rules.apply(item.input)
        let context = DictationContext(
            dictionary: PersonalDictionary(terms: item.vocabulary ?? []), snippets: snippets(item.snippets))
        emit(
            PrepOutput(
                id: item.id,
                rulesText: rules.text,
                cues: rules.cues.map(\.rawValue).sorted(),
                needsLLM: rules.needsLLM,
                messages: CleanupPrompt.messages(
                    dictation: rules.text, style: item.style ?? .standard,
                    vocabulary: DictationProcessor.cleanupVocabulary(for: rules.text, context: context)
                )
            ))
    }

case "budget":
    for item in readLines(BudgetCase.self) {
        emit(BudgetOutput(id: item.id, maxTokens: CleanupPrompt.maxOutputTokens(forInputTokens: item.inputTokens)))
    }

case "finish":
    let items = readLines(FinishCase.self)
    runAsync {
        for item in items {
            let processor = DictationProcessor(cleaner: item.llmOutput.map { RecordedCleaner(output: $0) })
            let context = DictationContext(
                style: item.style ?? .standard,
                mode: item.mode ?? (item.llmOutput == nil ? .rulesOnly : .always),
                dictionary: PersonalDictionary(terms: item.vocabulary ?? []),
                snippets: snippets(item.snippets),
                appendTrailingSpace: false
            )
            emit(FinishOutput(id: item.id, result: await processor.process(item.input, context: context)))
        }
    }

case "notes-replay":
    guard let line = readLine() else { fail("notes-replay: expected a meeting on the first line of stdin") }
    let meeting = decodeLine(line, as: ReplayInput.self)
    runAsync { await replay(meeting) }

case nil, "help", "-h", "--help":
    print(usage)

default:
    fail("unknown command \(args.first!)\n\n\(usage)")
}
