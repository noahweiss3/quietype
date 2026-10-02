import MurmurCore
import XCTest
import MurmurKit

/// Runs only when MURMUR_TEST_MODEL points at a GGUF file (CI downloads one).
final class LlamaCleanerTests: XCTestCase {
    private func loadCleaner() async throws -> LlamaCleaner {
        guard let path = ProcessInfo.processInfo.environment["MURMUR_TEST_MODEL"] else {
            throw XCTSkip("set MURMUR_TEST_MODEL to a GGUF model to run")
        }
        let id = ProcessInfo.processInfo.environment["MURMUR_TEST_MODEL_ID"] ?? CleanupModel.qwen3_4B.id
        return try await LlamaCleaner.load(CleanupModel.with(id: id) ?? .qwen3_4B, path: URL(fileURLWithPath: path))
    }

    func testSpeculativeDecodingMatchesGreedy() async throws {
        let cleaner = try await loadCleaner()
        let content = CleanupPrompt.userContent(dictation: "So the plan is, no wait, the new plan is to ship the beta on Thursday and then collect feedback from the first ten customers.")
        let fast = try await cleaner.complete(userContent: content, speculative: true)
        let plain = try await cleaner.complete(userContent: content, speculative: false)
        XCTAssertEqual(fast.text, plain.text)
        XCTAssertLessThan(fast.stats.decode.forwardPasses, plain.stats.decode.forwardPasses)
    }

    func testCleansACorrection() async throws {
        let cleaner = try await loadCleaner()
        let output = try await cleaner.clean("Let's meet at 2, no wait, 3 PM.", style: .standard, vocabulary: [])
        XCTAssertTrue(output.contains("3"), output)
        XCTAssertFalse(output.lowercased().contains("no wait"), output)
    }

    func testRepeatedCallsReuseThePrefix() async throws {
        let cleaner = try await loadCleaner()
        let first = try await cleaner.clean("I'll be there at noon. Scratch that. I'll be there at one.", style: .standard, vocabulary: [])
        let second = try await cleaner.clean("I'll be there at noon. Scratch that. I'll be there at one.", style: .standard, vocabulary: [])
        XCTAssertEqual(first, second)
    }
}
