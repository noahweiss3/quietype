import XCTest

@testable import QuietypeCore

final class AppStylesTests: XCTestCase {
    func testKnownAppsGetTheirStyle() {
        XCTAssertEqual(AppStyles.style(forBundleID: "com.tinyspeck.slackmacgap"), .chat)
        XCTAssertEqual(AppStyles.style(forBundleID: "com.apple.MobileSMS"), .chat)
        XCTAssertEqual(AppStyles.style(forBundleID: "com.apple.mail"), .email)
        XCTAssertEqual(AppStyles.style(forBundleID: "com.microsoft.Outlook"), .email)
        XCTAssertEqual(AppStyles.style(forBundleID: "com.apple.dt.Xcode"), .code)
        XCTAssertEqual(AppStyles.style(forBundleID: "com.apple.Terminal"), .code)
    }

    func testUnknownOrMissingAppsAreStandard() {
        XCTAssertEqual(AppStyles.style(forBundleID: nil), .standard)
        XCTAssertEqual(AppStyles.style(forBundleID: "com.example.notes"), .standard)
        XCTAssertEqual(AppStyles.style(forBundleID: ""), .standard)
    }

    func testEveryDefaultIsAStyleWithAPromptHint() {
        XCTAssertFalse(AppStyles.defaults.isEmpty)
        for (bundleID, style) in AppStyles.defaults {
            XCTAssertNotEqual(style, .standard, bundleID)
            XCTAssertEqual(AppStyles.style(forBundleID: bundleID), style, bundleID)
        }
    }
}
