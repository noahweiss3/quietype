import Foundation
import MurmurCore

// Thin JSON front end over MurmurCore so the cleanup prompt can be evaluated against any
// llama.cpp server (see evals/run_evals.py) using exactly the code the app runs.
//
//   murmur-cli rules "um so the the plan is"     rules pass only
//   murmur-cli prep  < cases.jsonl                rules + LLM messages per case
//   murmur-cli finish < results.jsonl             guard, fallback and dictionary per case

let usage = """
usage:
  murmur-cli rules <text>
  murmur-cli prep    reads JSONL {"id","input","style"?,"vocabulary"?}, writes {"id","rules_text","cues","needs_llm","messages"}
  murmur-cli finish  reads JSONL {"id","input","llm_output"?,"style"?,"vocabulary"?,"mode"?}, writes {"id","result"}
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
                appendTrailingSpace: false
            )
            emit(FinishOutput(id: item.id, result: await processor.process(item.input, context: context)))
        }
        done.signal()
    }
    done.wait()

default:
    print(usage)
    exit(args.isEmpty ? 0 : 1)
}
