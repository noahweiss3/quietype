import XCTest

@testable import QuietypeCore

final class WordsTests: XCTestCase {
    func testWordSeparatesPunctuationFromTheCoreAndKeepsBrandCapitalization() {
        let word = Word("\"don't,")
        XCTAssertEqual(word.leading, "\"")
        XCTAssertEqual(word.core, "don't")
        XCTAssertEqual(word.trailing, ",")
        var iphone = Word(core: "iPhone")
        iphone.capitalize()
        XCTAssertEqual(iphone.core, "iPhone")
    }
}
