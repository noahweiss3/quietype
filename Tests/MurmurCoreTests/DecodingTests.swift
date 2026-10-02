import XCTest
@testable import MurmurCore

/// A fake model whose greedy continuation is a fixed script, with KV-cache bookkeeping
/// that fails loudly if the decoder evaluates tokens at the wrong positions.
private struct ScriptedModel: GreedyLanguageModel {
    /// Prompt followed by the text the model "wants" to write, then the end token.
    var script: [Int]
    var cache: [Int]
    var calls = 0
    static let end = -1

    init(prompt: [Int], continuation: [Int]) {
        script = prompt + continuation + [Self.end]
        cache = prompt
    }

    mutating func evaluate(_ tokens: [Int], at position: Int) throws -> [Int] {
        precondition(position == cache.count, "evaluated at \(position), cache has \(cache.count)")
        calls += 1
        cache += tokens
        // Next token after position p is script[p + 1] if everything so far followed the script.
        return tokens.indices.map { i in
            let p = position + i
            return Array(cache[0...p]) == Array(script.prefix(p + 1)) && p + 1 < script.count ? script[p + 1] : Self.end
        }
    }

    mutating func truncate(from position: Int) throws {
        cache.removeLast(cache.count - position)
    }

    func isEndOfGeneration(_ token: Int) -> Bool { token == Self.end }
}

final class DecodingTests: XCTestCase {
    private func run(prompt: [Int], continuation: [Int], speculative: Bool, maxTokens: Int = 100) throws -> ([Int], DecodeStats) {
        var model = ScriptedModel(prompt: prompt, continuation: continuation)
        // The prompt has been evaluated and its last logits give the first token.
        let first = continuation.first ?? ScriptedModel.end
        model.cache = prompt
        let result = try SpeculativeDecoder.generate(
            model: &model, next: first, position: prompt.count,
            source: prompt, maxTokens: maxTokens, speculative: speculative
        )
        return result
    }

    func testSpeculativeMatchesPlainGreedyAndUsesFewerPasses() throws {
        let dictation = Array(100..<140)
        let prompt = [1, 2, 3] + dictation
        // Output copies the dictation with one word dropped and one changed.
        var continuation = Array(dictation[0..<10]) + Array(dictation[11..<25]) + [999] + Array(dictation[26...])
        continuation += [7]

        let (plain, plainStats) = try run(prompt: prompt, continuation: continuation, speculative: false)
        let (fast, fastStats) = try run(prompt: prompt, continuation: continuation, speculative: true)

        XCTAssertEqual(plain, continuation)
        XCTAssertEqual(fast, continuation)
        XCTAssertEqual(plainStats.forwardPasses, continuation.count)
        XCTAssertLessThan(fastStats.forwardPasses, continuation.count / 3)
        XCTAssertGreaterThan(fastStats.acceptedTokens, continuation.count / 2)
    }

    func testRespectsMaxTokens() throws {
        let prompt = Array(0..<50)
        let (output, _) = try run(prompt: prompt, continuation: Array(10..<50), speculative: true, maxTokens: 7)
        XCTAssertEqual(output, Array(10..<17))
    }

    func testStopsAtEndToken() throws {
        let (output, _) = try run(prompt: [1, 2, 3], continuation: [], speculative: true)
        XCTAssertEqual(output, [])
    }

    func testDraftLooksForwardFromTheCursor() {
        var drafter = PromptLookupDrafter(maxNgram: 2, maxDraft: 3)
        let source = [5, 6, 7, 8, 5, 6, 9, 9]
        XCTAssertEqual(drafter.draft(generated: [5, 6], source: source), [7, 8, 5])
        drafter.accept(3)
        // After copying through index 4, the next "5 6" match should be the later one.
        XCTAssertEqual(drafter.draft(generated: [5, 6], source: source), [9, 9])
        XCTAssertEqual(drafter.draft(generated: [42], source: source), [])
    }
}
