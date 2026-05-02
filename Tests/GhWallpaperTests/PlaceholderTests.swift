import XCTest
@testable import GhWallpaper

// Placeholder; Wave 2 Stream E replaces this with HTMLParserTests + fixtures.
final class PlaceholderTests: XCTestCase {
    func testThemesContainExpectedRamps() {
        XCTAssertEqual(Themes.githubDark.cellRamp.count, 5)
        XCTAssertEqual(Themes.githubLight.cellRamp.count, 5)
    }
}
