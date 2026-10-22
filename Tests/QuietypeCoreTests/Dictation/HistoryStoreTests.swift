import XCTest

@testable import QuietypeCore

final class HistoryStoreTests: XCTestCase {
    func testAddedEntriesAreLoadedBackUntilTheHistoryIsCleared() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quietype-\(UUID()).json")
        let store = HistoryStore(url: url, limit: 2)
        let result = ProcessedDictation(raw: "a", text: "A", path: .rules, note: nil, rulesSeconds: 0, llmSeconds: nil)
        for _ in 0..<3 {
            try store.add(
                HistoryEntry(
                    appBundleID: nil, audioSeconds: 1, transcribeSeconds: 0.1, totalSeconds: 0.2, result: result))
        }
        XCTAssertEqual(try store.load().count, 2)
        try store.clear()
        XCTAssertEqual(try store.load().count, 0)
    }

    func testMissingFileLoadsEmpty() throws {
        let store = HistoryStore(url: makeDirectory().appendingPathComponent("history.json"))
        XCTAssertEqual(try store.load(), [])
    }

    func testCorruptFileIsMovedAsideAndLoadThrows() throws {
        let directory = makeDirectory()
        let url = directory.appendingPathComponent("history.json")
        let corrupt = Data("{ not json".utf8)
        try corrupt.write(to: url)

        XCTAssertThrowsError(try HistoryStore(url: url).load())

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let aside = try movedAside(in: directory)
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try aside.first.map { try Data(contentsOf: $0) }, corrupt)
    }

    func testAddAfterCorruptFileStartsOverWithoutLosingTheOldBytes() throws {
        let directory = makeDirectory()
        let url = directory.appendingPathComponent("history.json")
        let corrupt = Data("{ not json".utf8)
        try corrupt.write(to: url)
        let store = HistoryStore(url: url)

        let entry = makeEntry("fresh")
        XCTAssertEqual(try store.add(entry), [entry])
        XCTAssertEqual(try store.load(), [entry])

        let aside = try movedAside(in: directory)
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try aside.first.map { try Data(contentsOf: $0) }, corrupt)
    }

    func testLoadErrorNamesTheFileTheHistoryWasKeptIn() throws {
        let directory = makeDirectory()
        let url = directory.appendingPathComponent("history.json")
        try Data("{ not json".utf8).write(to: url)

        do {
            _ = try HistoryStore(url: url).load()
            XCTFail("load should have thrown")
        } catch let HistoryError.unreadable(movedTo, _) {
            let aside = try movedAside(in: directory)
            XCTAssertEqual(aside.count, 1)
            XCTAssertEqual(movedTo?.lastPathComponent, aside.first?.lastPathComponent)
        }
    }

    func testHistoryThatCannotBeMovedAsideIsReportedAndNeverOverwritten() throws {
        try XCTSkipIf(getuid() == 0, "root can write to a read-only directory")
        let directory = makeDirectory()
        let url = directory.appendingPathComponent("history.json")
        let corrupt = Data("{ not json".utf8)
        try corrupt.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }
        let store = HistoryStore(url: url)

        do {
            _ = try store.load()
            XCTFail("load should have thrown")
        } catch let HistoryError.unreadable(movedTo, _) {
            XCTAssertNil(movedTo)
        }
        XCTAssertThrowsError(try store.add(makeEntry("fresh")))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testLimitKeepsTheNewestEntries() throws {
        let store = HistoryStore(url: makeDirectory().appendingPathComponent("history.json"), limit: 2)
        let entries = ["one", "two", "three"].map(makeEntry)
        for entry in entries { try store.add(entry) }
        XCTAssertEqual(try store.load(), [entries[2], entries[1]])
    }

    func testClearRemovesUnreadableCopiesAndLeavesOtherFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quietype-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let store = HistoryStore(url: url)

        // Two unreadable histories in the same second, so the second copy gets a numbered name.
        for _ in 0..<2 {
            try Data("{ not json".utf8).write(to: url)
            XCTAssertThrowsError(try store.load())
        }
        let result = ProcessedDictation(raw: "a", text: "A", path: .rules, note: nil, rulesSeconds: 0, llmSeconds: nil)
        try store.add(
            HistoryEntry(appBundleID: nil, audioSeconds: 1, transcribeSeconds: 0.1, totalSeconds: 0.2, result: result))
        let unrelated = ["other.json", "history.unreadable-notes.txt"].map { directory.appendingPathComponent($0) }
        for file in unrelated { try Data("keep".utf8).write(to: file) }
        XCTAssertEqual(
            try names(in: directory).filter { $0.hasPrefix("history.unreadable-") && $0.hasSuffix(".json") }.count, 2)

        try store.clear()

        XCTAssertEqual(try names(in: directory), Set(unrelated.map(\.lastPathComponent)))
        XCTAssertEqual(try store.load(), [])
    }

    func testClearWithNoFolderSucceeds() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("quietype-\(UUID())/history.json")
        XCTAssertNoThrow(try HistoryStore(url: missing).clear())
    }

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quietype-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeEntry(_ text: String) -> HistoryEntry {
        let result = ProcessedDictation(
            raw: text, text: text, path: .rules, note: nil, rulesSeconds: 0, llmSeconds: nil)
        return HistoryEntry(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            appBundleID: nil,
            audioSeconds: 1,
            transcribeSeconds: 0.1,
            totalSeconds: 0.2,
            result: result
        )
    }

    private func movedAside(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("history.unreadable-") && $0.pathExtension == "json" }
    }

    private func names(in directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }
}
