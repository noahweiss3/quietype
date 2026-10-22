import Foundation
import QuietypeCore
import QuietypeKit

let modelIDs = CleanupModel.all.map(\.id).joined(separator: ", ")
let modes = CleanupMode.allCases.map(\.rawValue).joined(separator: ", ")
let speechVariants = ParakeetTranscriber.Variant.allCases.map(\.rawValue).joined(separator: ", ")

let usage = """
    usage: quietype-bench [--model <file.gguf>] [--model-id <id>] [--mode <mode>] [--compare] [--expect <file.json>]
                        [--audio <file>]... [--text <text>]... [--cases <file.jsonl>] [--speech <variant>]

    At least one --audio, --text or --cases input is required.

      --model <file.gguf>   Cleanup model. Without it only the rules pass runs.
      --model-id <id>       Which model the file is, for its chat template: \(modelIDs).
                            Default \(CleanupModel.qwen3_4B.id).
      --mode <mode>         When the LLM runs: \(modes). Default smart.
      --compare             Run every input through the LLM with and without speculative decoding;
                            fail if the answers differ or either is cut off. Needs --model.
      --expect <file.json>  Check results against expectations, keyed by input id (an --audio path as
                            given, text0, text1, … for --text, or a case id):
                              {"<id>": {"transcript": [...], "output": [...], "output_not": [...],
                                        "path": "rules" | "llm" | "llmRejected"}}
                            transcript and output list words the speech transcript (--audio only) and
                            the cleaned text must contain, ignoring case; an entry may be a list of
                            alternatives, such as ["three", "3"]. output_not lists words the cleaned
                            text must not contain. Every listed input must also come out non-empty.
      --audio <file>        Transcribe an audio file the way the app does, then clean it up. Repeatable.
      --text <text>         Clean up this text. Repeatable.
      --cases <file.jsonl>  Clean up every case in an eval file, such as evals/cases/cleanup.jsonl,
                            with its style, vocabulary and snippets.
      --speech <variant>    Speech model for --audio: \(speechVariants). Default ultra.

    Exits 1 when a check fails: an empty transcript, a cleanup that errors or is cut off, a
    --compare mismatch or an --expect expectation. Exits 2 on a usage or input-file error.
    """

struct Options {
    var modelPath: String?
    var model = CleanupModel.qwen3_4B
    var audio: [String] = []
    var texts: [String] = []
    var casesPath: String?
    var expectPath: String?
    var compare = false
    var speech = ParakeetTranscriber.Variant.ultra
    var mode = CleanupMode.smart
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("quietype-bench: \(message)\n\n\(usage)\n".utf8))
    exit(2)
}

func parse() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    func value(of flag: String) -> String {
        guard let value = args.next(), !value.hasPrefix("--") else { fail("\(flag) needs a value") }
        return value
    }
    while let arg = args.next() {
        switch arg {
        case "-h", "--help":
            print(usage)
            exit(0)
        case "--model": options.modelPath = value(of: arg)
        case "--model-id":
            let id = value(of: arg)
            guard let model = CleanupModel.with(id: id) else {
                fail("--model-id must be one of \(modelIDs), not \(id)")
            }
            options.model = model
        case "--audio": options.audio.append(value(of: arg))
        case "--text": options.texts.append(value(of: arg))
        case "--cases": options.casesPath = value(of: arg)
        case "--expect": options.expectPath = value(of: arg)
        case "--compare": options.compare = true
        case "--speech":
            let name = value(of: arg)
            guard let speech = ParakeetTranscriber.Variant(rawValue: name) else {
                fail("--speech must be one of \(speechVariants), not \(name)")
            }
            options.speech = speech
        case "--mode":
            let name = value(of: arg)
            guard let mode = CleanupMode(rawValue: name) else { fail("--mode must be one of \(modes), not \(name)") }
            options.mode = mode
        default:
            fail("unknown argument \(arg)")
        }
    }
    guard !options.audio.isEmpty || !options.texts.isEmpty || options.casesPath != nil else {
        fail("nothing to run: pass --audio, --text or --cases")
    }
    if options.compare, options.modelPath == nil { fail("--compare needs --model") }
    return options
}

struct Case: Decodable {
    var id: String
    var input: String
    var style: WritingStyle?
    var vocabulary: [String]?
    var snippets: [SnippetSpec]?
}

struct Input {
    var id: String
    var text: String
    var style = WritingStyle.standard
    var vocabulary: [String] = []
    var snippets = Snippets()
}

/// One entry of an expectation list: a word, or alternatives of which one must appear.
struct Alternatives: Decodable, CustomStringConvertible {
    var options: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let one = try? container.decode(String.self) {
            options = [one]
        } else {
            options = try container.decode([String].self)
        }
        guard !options.isEmpty, options.allSatisfy({ !$0.isEmpty }) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "an entry needs non-empty strings")
        }
    }

    func found(in text: String) -> Bool { options.contains { text.localizedCaseInsensitiveContains($0) } }

    var description: String { options.map { "\"\($0)\"" }.joined(separator: " or ") }
}

struct Expectation: Decodable {
    var transcript: [Alternatives]?
    var output: [Alternatives]?
    var outputNot: [String]?
    var path: ProcessedDictation.Path?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case transcript, output, path
        case outputNot = "output_not"
    }
}

func readCases(_ path: String) -> [Input] {
    let lines: [Substring]
    do {
        lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
    } catch {
        fail("can't read \(path): \(error.localizedDescription)")
    }
    return lines.enumerated().compactMap { number, line in
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        do {
            let item = try JSONDecoder().decode(Case.self, from: Data(line.utf8))
            return Input(
                id: item.id, text: item.input, style: item.style ?? .standard, vocabulary: item.vocabulary ?? [],
                snippets: Snippets((item.snippets ?? []).map(\.snippet))
            )
        } catch {
            fail("\(path):\(number + 1): \(error)")
        }
    }
}

/// Reads --expect and rejects ids that match no input and keys it doesn't know, so a typo can't
/// turn a check into a silent pass.
func readExpectations(_ path: String, inputIDs: Set<String>, audioIDs: Set<String>) -> [String: Expectation] {
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
        fail("can't read \(path): \(error.localizedDescription)")
    }
    let known = Set(Expectation.CodingKeys.allCases.map(\.rawValue))
    guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fail("\(path) must be a JSON object of input ids")
    }
    for (id, value) in raw {
        guard let fields = value as? [String: Any] else { fail("\(path): \(id) must map to an object") }
        let unknown = Set(fields.keys).subtracting(known)
        if !unknown.isEmpty { fail("\(path): unknown keys \(unknown.sorted()) for \(id)") }
        if !inputIDs.contains(id) {
            fail("\(path): \(id) is not one of the inputs (\(inputIDs.sorted().joined(separator: ", ")))")
        }
        if fields["transcript"] != nil, !audioIDs.contains(id) {
            fail("\(path): \(id) has no transcript; only --audio inputs do")
        }
    }
    do {
        return try JSONDecoder().decode([String: Expectation].self, from: data)
    } catch {
        fail("\(path): \(error)")
    }
}

/// Hands cleanups to the model and keeps the last error, which DictationProcessor would
/// otherwise turn into a quiet fallback to the rules text.
///
/// `@unchecked Sendable`: `error` is only touched under `lock`.
final class CheckedCleaner: TextCleaner, @unchecked Sendable {
    let model: LlamaCleaner
    private let lock = NSLock()
    private var error: Error?

    init(_ model: LlamaCleaner) {
        self.model = model
    }

    func clean(_ dictation: String, style: WritingStyle, vocabulary: [String]) async throws -> String {
        do {
            return try await model.clean(dictation, style: style, vocabulary: vocabulary)
        } catch {
            lock.withLock { self.error = error }
            throw error
        }
    }

    /// The error from the cleanups since the last call, if any.
    func takeError() -> Error? {
        lock.withLock {
            defer { error = nil }
            return error
        }
    }
}

func ms(_ seconds: Double) -> String { String(format: "%.0f ms", seconds * 1000) }

func log(_ text: String) {
    print(text)
    fflush(stdout)
}

let options = parse()
var failures = 0

@MainActor
func check(_ ok: Bool, _ message: @autoclosure () -> String) {
    if !ok {
        failures += 1
        log("  FAIL: \(message())")
    }
}

var textInputs = options.texts.enumerated().map { Input(id: "text\($0.offset)", text: $0.element) }
if let casesPath = options.casesPath { textInputs += readCases(casesPath) }
let expectations =
    options.expectPath.map {
        readExpectations($0, inputIDs: Set(textInputs.map(\.id) + options.audio), audioIDs: Set(options.audio))
    } ?? [:]

do {
    var cleaner: CheckedCleaner?
    if let path = options.modelPath {
        let started = Date()
        let model = try await LlamaCleaner.load(
            options.model, path: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        log("cleanup model loaded in \(ms(Date().timeIntervalSince(started)))")
        let speculation = model.speculationPaysOff ? "on" : "off (not worth it on this GPU)"
        let cost = String(format: "%.2f", model.batchCostRatio)
        log("batch-of-8 cost: \(cost)x a single token, speculative decoding \(speculation)")
        cleaner = CheckedCleaner(model)
    }
    let processor = DictationProcessor(cleaner: cleaner)

    var inputs = textInputs
    if !options.audio.isEmpty {
        let transcriber = ParakeetTranscriber()
        let started = Date()
        try await transcriber.load(options.speech)
        log("speech model \(options.speech.rawValue) loaded in \(ms(Date().timeIntervalSince(started)))")

        for path in options.audio {
            let samples = try ParakeetTranscriber.loadAudioFile(URL(fileURLWithPath: path))
            let live = LiveTranscription(transcriber: transcriber)
            for start in stride(from: 0, to: samples.count, by: 1600) {
                await live.append(Array(samples[start..<min(samples.count, start + 1600)]))
            }
            let result = try await live.finish()
            let seconds = String(format: "%.1f", result.audioSeconds)
            log(
                "\n[\(path)] \(seconds)s audio, \(result.segments) segments, "
                    + "tail transcribed in \(ms(result.finishSeconds))"
            )
            log("  transcript: \(result.text)")
            check(!result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "empty transcript")
            for words in expectations[path]?.transcript ?? [] where !words.found(in: result.text) {
                check(false, "transcript is missing \(words)")
            }
            inputs.append(Input(id: path, text: result.text))
        }
    }

    for input in inputs {
        let context = DictationContext(
            style: input.style, mode: options.mode, dictionary: PersonalDictionary(terms: input.vocabulary),
            snippets: input.snippets, appendTrailingSpace: false
        )
        let processed = await processor.process(input.text, context: context)
        var line = "\n[\(input.id)] \(processed.path.rawValue)"
        if let llm = processed.llmSeconds { line += ", cleanup \(ms(llm))" }
        if let stats = cleaner?.model.lastStats, processed.llmSeconds != nil {
            line +=
                " (prefill \(stats.promptTokens) tok \(ms(stats.prefillSeconds)), generate \(stats.outputTokens) tok"
                + " in \(stats.decode.forwardPasses) passes \(ms(stats.generateSeconds)))"
        }
        log(line)
        log("  in:  \(input.text)")
        log("  out: \(processed.text.replacingOccurrences(of: "\n", with: "\\n"))")
        if let note = processed.note { log("  note: \(note)") }
        if let error = cleaner?.takeError() { check(false, "cleanup failed: \(error)") }

        if let expected = expectations[input.id] {
            check(!processed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "empty output")
            if let path = expected.path {
                check(processed.path == path, "went through \(processed.path.rawValue), expected \(path.rawValue)")
            }
            for words in expected.output ?? [] where !words.found(in: processed.text) {
                check(false, "output is missing \(words)")
            }
            for word in expected.outputNot ?? [] where processed.text.localizedCaseInsensitiveContains(word) {
                check(false, "output contains \"\(word)\"")
            }
        }

        // Every input the model could see, not only those the mode sends to it, so the
        // comparison doesn't depend on what the rules pass routes to the model.
        let rules = Rules.apply(input.text)
        if options.compare, let cleaner, !rules.text.isEmpty {
            let content = CleanupPrompt.userContent(
                dictation: rules.text, style: input.style,
                vocabulary: DictationProcessor.cleanupVocabulary(for: rules.text, context: context)
            )
            let fast = try await cleaner.model.complete(userContent: content, speculative: true)
            let plain = try await cleaner.model.complete(userContent: content, speculative: false)
            let same = fast.text == plain.text
            log(
                "  speculative \(ms(fast.stats.generateSeconds)) vs plain \(ms(plain.stats.generateSeconds)): "
                    + (same ? "identical" : "DIFFERENT"))
            check(
                same,
                "speculative and plain decoding differ\n    speculative: \(fast.text)\n    plain:       \(plain.text)"
            )
            check(
                fast.stats.stop == .endOfGeneration,
                "speculative answer cut off at \(fast.stats.outputTokens) tokens")
            check(
                plain.stats.stop == .endOfGeneration, "plain answer cut off at \(plain.stats.outputTokens) tokens")
        }
    }
} catch {
    log("error: \(error)")
    failures += 1
}
if failures > 0 { log("\n\(failures) check\(failures == 1 ? "" : "s") failed") }
exit(failures == 0 ? 0 : 1)
