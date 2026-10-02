import Accelerate
import Foundation
import llama
import MurmurCore

public enum LlamaError: Error, CustomStringConvertible {
    case modelLoadFailed(String)
    case contextFailed
    case tokenizeFailed
    case templateFailed
    case decodeFailed(Int32)
    case cacheTrimFailed
    case promptTooLong(Int)

    public var description: String {
        switch self {
        case let .modelLoadFailed(path): return "could not load model at \(path)"
        case .contextFailed: return "could not create llama context"
        case .tokenizeFailed: return "tokenization failed"
        case .templateFailed: return "chat template failed"
        case let .decodeFailed(code): return "llama_decode failed (\(code))"
        case .cacheTrimFailed: return "could not trim the KV cache"
        case let .promptTooLong(tokens): return "dictation too long for the cleanup context (\(tokens) tokens)"
        }
    }
}

private let backendInit: Void = {
    llama_backend_init()
    if ProcessInfo.processInfo.environment["MURMUR_LLAMA_LOG"] == nil {
        llama_log_set({ _, _, _ in }, nil)
    }
}()

/// One llama.cpp model and context. Not thread-safe; `LlamaCleaner` serializes all access.
final class LlamaSession {
    let model: OpaquePointer
    let context: OpaquePointer
    let vocab: OpaquePointer
    let contextLength: Int
    private var batch: llama_batch
    private let batchCapacity: Int32 = 512
    private let vocabSize: Int

    init(modelPath: String, contextLength: Int = 4096, gpuLayers: Int32 = 999) throws {
        _ = backendInit

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = gpuLayers
        guard let model = llama_model_load_from_file(modelPath, modelParams) else {
            throw LlamaError.modelLoadFailed(modelPath)
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextLength)
        contextParams.n_batch = UInt32(batchCapacity)
        contextParams.n_ubatch = UInt32(batchCapacity)
        let threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads
        contextParams.no_perf = true
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw LlamaError.contextFailed
        }

        self.model = model
        self.context = context
        self.contextLength = contextLength
        vocab = llama_model_get_vocab(model)
        vocabSize = Int(llama_vocab_n_tokens(vocab))
        batch = llama_batch_init(batchCapacity, 0, 1)
    }

    deinit {
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
    }

    // MARK: Text

    func tokenize(_ text: String, addSpecial: Bool) throws -> [llama_token] {
        let byteCount = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(byteCount) + 16)
        var count = llama_tokenize(vocab, text, byteCount, &tokens, Int32(tokens.count), addSpecial, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, byteCount, &tokens, Int32(tokens.count), addSpecial, true)
        }
        guard count >= 0 else { throw LlamaError.tokenizeFailed }
        return Array(tokens.prefix(Int(count)))
    }

    func detokenize(_ tokens: [llama_token]) -> String {
        var bytes: [UInt8] = []
        var buffer = [CChar](repeating: 0, count: 64)
        for token in tokens {
            var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
            if count < 0 {
                buffer = [CChar](repeating: 0, count: Int(-count))
                count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
            }
            bytes += buffer.prefix(Int(max(0, count))).map { UInt8(bitPattern: $0) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Renders messages with the model's chat template (falls back to ChatML).
    func applyTemplate(_ messages: [ChatMessage], addAssistant: Bool) throws -> String {
        let template = llama_model_chat_template(model, nil)
        let roles = messages.map { strdup($0.role) }
        let contents = messages.map { strdup($0.content) }
        defer {
            roles.forEach { free($0) }
            contents.forEach { free($0) }
        }
        var chat = zip(roles, contents).map { llama_chat_message(role: UnsafePointer($0), content: UnsafePointer($1)) }
        var capacity = messages.reduce(0) { $0 + $1.content.utf8.count + $1.role.utf8.count } * 2 + 1024

        for _ in 0..<2 {
            var buffer = [CChar](repeating: 0, count: capacity)
            let written = template.map {
                llama_chat_apply_template($0, &chat, chat.count, addAssistant, &buffer, Int32(capacity))
            } ?? llama_chat_apply_template("chatml", &chat, chat.count, addAssistant, &buffer, Int32(capacity))
            guard written >= 0 else { throw LlamaError.templateFailed }
            if Int(written) <= capacity {
                return String(decoding: buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            capacity = Int(written) + 1
        }
        throw LlamaError.templateFailed
    }

    // MARK: Evaluation

    /// Evaluates `tokens` starting at `position` in sequence 0. Logits are kept for every token
    /// when `allLogits` is set (verification), otherwise only for the last one.
    func decode(_ tokens: [llama_token], at position: Int, allLogits: Bool) throws {
        var offset = 0
        while offset < tokens.count {
            let count = min(Int(batchCapacity), tokens.count - offset)
            batch.n_tokens = Int32(count)
            for i in 0..<count {
                batch.token[i] = tokens[offset + i]
                batch.pos[i] = llama_pos(position + offset + i)
                batch.n_seq_id[i] = 1
                batch.seq_id[i]![0] = 0
                batch.logits[i] = (allLogits || offset + i == tokens.count - 1) ? 1 : 0
            }
            let result = llama_decode(context, batch)
            guard result == 0 else { throw LlamaError.decodeFailed(result) }
            offset += count
        }
    }

    /// Most likely next token after the `index`-th output of the last decode (-1 = last).
    func argmax(at index: Int32) -> llama_token {
        guard let logits = llama_get_logits_ith(context, index) else { return llama_vocab_eos(vocab) }
        var maxValue: Float = 0
        var maxIndex: vDSP_Length = 0
        vDSP_maxvi(logits, 1, &maxValue, &maxIndex, vDSP_Length(vocabSize))
        return llama_token(maxIndex)
    }

    func removeTokens(from position: Int) throws {
        guard llama_memory_seq_rm(llama_get_memory(context), 0, llama_pos(position), -1) else {
            throw LlamaError.cacheTrimFailed
        }
    }

    func isEndOfGeneration(_ token: llama_token) -> Bool {
        llama_vocab_is_eog(vocab, token)
    }
}

/// Adapts a session to the decoder in MurmurCore.
struct LlamaGreedyModel: GreedyLanguageModel {
    let session: LlamaSession

    mutating func evaluate(_ tokens: [llama_token], at position: Int) throws -> [llama_token] {
        try session.decode(tokens, at: position, allLogits: true)
        return (0..<tokens.count).map { session.argmax(at: Int32($0)) }
    }

    mutating func truncate(from position: Int) throws {
        try session.removeTokens(from: position)
    }

    func isEndOfGeneration(_ token: llama_token) -> Bool {
        session.isEndOfGeneration(token)
    }
}
