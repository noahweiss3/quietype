import XCTest

@testable import QuietypeCore

final class PersonalDictionaryTests: XCTestCase {
    private let dictionary = PersonalDictionary(
        parsing: """
            # names
            GitHub
            cooper netties -> Kubernetes
            Figma
            """)

    func testParsingSkipsCommentsAndKeepsThePreferredSpellings() {
        XCTAssertEqual(dictionary.terms, ["GitHub", "Kubernetes", "Figma"])
    }

    func testTermsAndSpokenReplacementsAreAppliedToTheText() {
        XCTAssertEqual(
            dictionary.apply(to: "Push it to github and deploy on cooper netties."),
            "Push it to GitHub and deploy on Kubernetes."
        )
    }

    func testTermsInsideLongerWordsAreLeftAlone() {
        XCTAssertEqual(dictionary.apply(to: "githubber"), "githubber")
    }
}
