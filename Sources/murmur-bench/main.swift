import Foundation
import MurmurCore
import MurmurKit

// Runs Murmur's pipeline outside the app, for latency numbers and CI checks.
//
//   murmur-bench --model ~/Library/Application\ Support/Murmur/Models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf \
//                [--model-id qwen3-4b-instruct-2507] [--audio a.wav ...] [--text "..." ...]
//                [--cases evals/cases.jsonl] [--compare] [--speech ultra]
//
// --compare runs every LLM call with and without speculative decoding and fails if they differ.

struct Options {
    var modelPath: String?
    var modelID = CleanupModel.qwen3_4B.id
    var audio: [String] = []
    var texts: [String] = []
    var casesPath: String?
    var compare = false
    var speech = ParakeetTranscriber.Variant.ultra
    var mode = CleanupMode.smart
}

func parse() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--model": options.modelPath = args.next()
        case "--model-id": options.modelID = args.next() ?? options.modelID
        case "--audio": args.next().map { options.audio.append($0) }
        case "--text": args.next().map { options.texts.append($0) }
        case "--cases": options.casesPath = args.next()
        case "--compare": options.compare = true
        case "--speech": options.speech = args.next().flatMap(ParakeetTranscriber.Variant.init(rawValue:)) ?? .ultra
        case "--mode": options.mode = args.next().flatMap(CleanupMode.init(rawValue:)) ?? .smart
        default:
            FileHandle.standardError.write(Data("unknown argument \(arg)\n".utf8))
            exit(2)
        }
    }
    return options
}

struct Case: Decodable {
    var id: String
    var input: String
    var style: WritingStyle?
    var vocabulary: [String]?
}

func ms(_ seconds: Double) -> String { String(format: "%.0f ms", seconds * 1000) }

func log(_ text: String) {
    print(text)
    fflush(stdout)
}

let options = parse()
var failures = 0

let done = DispatchSemaphore(value: 0)
Task {
    defer { done.signal() }
    do {
        var cleaner: LlamaCleaner?
        if let path = options.modelPath {
            let model = CleanupModel.with(id: options.modelID) ?? .qwen3_4B
            let started = Date()
            cleaner = try await LlamaCleaner.load(model, path: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            log("cleanup model loaded in \(ms(Date().timeIntervalSince(started)))")
            if let cleaner {
                log(String(format: "batch-of-8 cost: %.2fx a single token, speculative decoding %@", cleaner.batchCostRatio, cleaner.speculationPaysOff ? "on" : "off (not worth it on this GPU)"))
            }
        }
        let processor = DictationProcessor(cleaner: cleaner)

        var inputs: [(id: String, text: String, style: WritingStyle, vocabulary: [String])] =
            options.texts.enumerated().map { ("text\($0.offset)", $0.element, .standard, []) }
        if let casesPath = options.casesPath {
            let lines = try String(contentsOfFile: casesPath, encoding: .utf8).split(separator: "\n")
            for line in lines where !line.isEmpty {
                let item = try JSONDecoder().decode(Case.self, from: Data(line.utf8))
                inputs.append((item.id, item.input, item.style ?? .standard, item.vocabulary ?? []))
            }
        }

        if !options.audio.isEmpty {
            let transcriber = ParakeetTranscriber()
            let started = Date()
            try await transcriber.load(options.speech)
            log("speech model \(options.speech.rawValue) loaded in \(ms(Date().timeIntervalSince(started)))")

            for path in options.audio {
                let samples = try ParakeetTranscriber.loadAudioFile(URL(fileURLWithPath: path))
                // Feed it the way the app does: in 100 ms chunks, then finish.
                let live = LiveTranscription(transcriber: transcriber)
                for start in stride(from: 0, to: samples.count, by: 1600) {
                    await live.append(Array(samples[start..<min(samples.count, start + 1600)]))
                }
                let result = try await live.finish()
                log("\n[\(path)] \(String(format: "%.1f", result.audioSeconds))s audio, \(result.segments) segments, tail transcribed in \(ms(result.finishSeconds))")
                log("  transcript: \(result.text)")
                inputs.append((path, result.text, .standard, []))
            }
        }

        for input in inputs {
            let context = DictationContext(style: input.style, mode: options.mode, dictionary: PersonalDictionary(terms: input.vocabulary), appendTrailingSpace: false)
            let processed = await processor.process(input.text, context: context)
            var line = "\n[\(input.id)] \(processed.path.rawValue)"
            if let llm = processed.llmSeconds { line += ", cleanup \(ms(llm))" }
            if let stats = cleaner?.lastStats, processed.llmSeconds != nil {
                line += " (prefill \(stats.promptTokens) tok \(ms(stats.prefillSeconds)), generate \(stats.outputTokens) tok in \(stats.decode.forwardPasses) passes \(ms(stats.generateSeconds)))"
            }
            log(line)
            log("  in:  \(input.text)")
            log("  out: \(processed.text.replacingOccurrences(of: "\n", with: "\\n"))")
            if let note = processed.note { log("  note: \(note)") }

            if options.compare, let cleaner, processed.llmSeconds != nil {
                let rules = Rules.apply(input.text)
                let content = CleanupPrompt.userContent(dictation: rules.text, style: input.style, vocabulary: input.vocabulary)
                let fast = try await cleaner.complete(userContent: content, speculative: true)
                let plain = try await cleaner.complete(userContent: content, speculative: false)
                let same = fast.text == plain.text
                if !same { failures += 1 }
                log("  speculative \(ms(fast.stats.generateSeconds)) vs plain \(ms(plain.stats.generateSeconds)): \(same ? "identical" : "DIFFERENT")")
                if !same {
                    log("    speculative: \(fast.text)")
                    log("    plain:       \(plain.text)")
                }
            }
        }
    } catch {
        log("error: \(error)")
        failures += 1
    }
}
done.wait()
exit(failures == 0 ? 0 : 1)
