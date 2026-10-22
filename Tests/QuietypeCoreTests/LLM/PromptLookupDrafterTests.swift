import XCTest

@testable import QuietypeCore

final class PromptLookupDrafterTests: XCTestCase {
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
