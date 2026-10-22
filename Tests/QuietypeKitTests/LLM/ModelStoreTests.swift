import CryptoKit
import XCTest

@testable import QuietypeKit

/// Download checks and model metadata, on small temporary files: no model download needed.
final class ModelStoreTests: XCTestCase {
    private let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    func testSHA256MatchesKnownDigestsAndReadsAcrossChunks() throws {
        XCTAssertEqual(try ModelStore.sha256(of: makeFile(Data("abc".utf8))), abcDigest)
        XCTAssertEqual(
            try ModelStore.sha256(of: makeFile(Data())),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        // Longer than the 1 MiB read buffer, so the digest spans more than one chunk.
        let large = Data((0..<(1 << 20) + 4_099).map { UInt8($0 % 251) })
        let expected = SHA256.hash(data: large).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try ModelStore.sha256(of: makeFile(large)), expected)
    }

    func testVerifyAcceptsAFileOfTheRightSizeAndHash() throws {
        let file = try makeFile(Data("abc".utf8))
        XCTAssertNoThrow(try ModelStore.verify(file, against: model(bytes: 3, sha256: abcDigest)))
    }

    func testVerifyRejectsTheWrongSizeBeforeHashing() throws {
        let file = try makeFile(Data("abc".utf8))
        XCTAssertThrowsError(try ModelStore.verify(file, against: model(bytes: 4, sha256: abcDigest))) { error in
            guard case let ModelStore.DownloadError.sizeMismatch(expected, actual) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(expected, 4)
            XCTAssertEqual(actual, 3)
        }
    }

    func testVerifyTreatsAMissingFileAsEmpty() throws {
        let missing = try makeDirectory().appendingPathComponent("missing.gguf")
        XCTAssertThrowsError(try ModelStore.verify(missing, against: model(bytes: 3, sha256: abcDigest))) { error in
            guard case let ModelStore.DownloadError.sizeMismatch(_, actual) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(actual, 0)
        }
    }

    func testVerifyRejectsTheWrongHash() throws {
        let file = try makeFile(Data("abd".utf8))
        XCTAssertThrowsError(try ModelStore.verify(file, against: model(bytes: 3, sha256: abcDigest))) { error in
            guard case let ModelStore.DownloadError.checksumMismatch(expected, actual) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(expected, abcDigest)
            XCTAssertNotEqual(actual, abcDigest)
            XCTAssertEqual(actual.count, 64)
        }
    }

    func testModelURLPointsAtThePinnedFile() {
        XCTAssertEqual(
            CleanupModel.qwen3_4B.url.absoluteString,
            "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/"
                + "a06e946bb6b655725eafa393f4a9745d460374c9/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
        )
        for model in CleanupModel.all {
            XCTAssertEqual(model.url.host, "huggingface.co", model.id)
            XCTAssertEqual(model.url.lastPathComponent, model.fileName, model.id)
            XCTAssertEqual(ModelStore.path(for: model).lastPathComponent, model.fileName, model.id)
            XCTAssertTrue(isHex(model.revision, count: 40), model.id)
            XCTAssertTrue(isHex(model.sha256, count: 64), model.id)
            XCTAssertGreaterThan(model.bytes, 0, model.id)
        }
    }

    func testModelsAreFoundByTheirIDs() {
        XCTAssertEqual(Set(CleanupModel.all.map(\.id)).count, CleanupModel.all.count)
        for model in CleanupModel.all { XCTAssertEqual(CleanupModel.with(id: model.id), model) }
        XCTAssertEqual(CleanupModel.with(id: "qwen3-4b-instruct-2507"), CleanupModel.qwen3_4B)
        XCTAssertEqual(CleanupModel.with(id: "qwen3-1.7b"), CleanupModel.qwen3_1_7B)
        XCTAssertNil(CleanupModel.with(id: "no-such-model"))
    }

    private func model(bytes: Int64, sha256: String) -> CleanupModel {
        CleanupModel(
            id: "test", name: "Test", detail: "", repository: "example/test",
            revision: String(repeating: "0", count: 40),
            fileName: "test.gguf", bytes: bytes, sha256: sha256, assistantPrefill: ""
        )
    }

    private func isHex(_ text: String, count: Int) -> Bool {
        text.count == count && text.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quietype-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeFile(_ contents: Data) throws -> URL {
        let file = try makeDirectory().appendingPathComponent("model.gguf")
        try contents.write(to: file)
        return file
    }
}
