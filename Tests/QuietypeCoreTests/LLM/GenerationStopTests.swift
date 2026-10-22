import XCTest

@testable import QuietypeCore

/// Writes a fixed continuation after the prompt, then the end token.
private struct FixedAnswerModel: GreedyLanguageModel {
    var script: [Int]
    var cache: [Int]
    static let end = -1

    init(prompt: [Int], answer: [Int]) {
        script = prompt + answer + [Self.end]
        cache = prompt
    }

    mutating func evaluate(_ tokens: [Int], at position: Int) throws -> [Int] {
        precondition(position == cache.count, "evaluated at \(position), cache has \(cache.count)")
        cache += tokens
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

final class GenerationStopTests: XCTestCase {
    private func generate(answer: [Int], maxTokens: Int, speculative: Bool) throws -> ([Int], GenerationStop) {
        // The answer copies the prompt, so speculative runs accept drafts right up to the limit.
        let prompt = [1, 2, 3] + answer
        var model = FixedAnswerModel(prompt: prompt, answer: answer)
        let (tokens, stats) = try SpeculativeDecoder.generate(
            model: &model, next: answer.first ?? FixedAnswerModel.end, position: prompt.count,
            source: prompt, maxTokens: maxTokens, speculative: speculative
        )
        return (tokens, stats.stop)
    }

    func testAnswerEndingBeforeTheLimitIsFinished() throws {
        for speculative in [false, true] {
            let (tokens, stop) = try generate(answer: Array(10..<15), maxTokens: 20, speculative: speculative)
            XCTAssertEqual(tokens, Array(10..<15))
            XCTAssertEqual(stop, .endOfGeneration, "speculative: \(speculative)")
        }
    }

    func testAnswerEndingExactlyAtTheLimitIsFinished() throws {
        for speculative in [false, true] {
            let (tokens, stop) = try generate(answer: Array(10..<17), maxTokens: 7, speculative: speculative)
            XCTAssertEqual(tokens, Array(10..<17))
            XCTAssertEqual(stop, .endOfGeneration, "speculative: \(speculative)")
        }
    }

    func testAnswerLongerThanTheLimitIsCutOff() throws {
        for speculative in [false, true] {
            let (tokens, stop) = try generate(answer: Array(10..<30), maxTokens: 7, speculative: speculative)
            XCTAssertEqual(tokens, Array(10..<17))
            XCTAssertEqual(stop, .tokenLimit, "speculative: \(speculative)")
        }
    }

    func testOneTokenOverTheLimitIsCutOff() throws {
        for speculative in [false, true] {
            let (tokens, stop) = try generate(answer: Array(10..<18), maxTokens: 7, speculative: speculative)
            XCTAssertEqual(tokens, Array(10..<17))
            XCTAssertEqual(stop, .tokenLimit, "speculative: \(speculative)")
        }
    }
}
