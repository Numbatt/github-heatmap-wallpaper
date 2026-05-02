import XCTest
@testable import GhWallpaper

// Placeholder; Wave 2 Stream E replaces this with HTMLParserTests + fixtures.
final class PlaceholderTests: XCTestCase {
    func testThemesContainExpectedRamps() {
        XCTAssertEqual(Themes.githubDark.cellRamp.count, 5)
        XCTAssertEqual(Themes.githubLight.cellRamp.count, 5)
        XCTAssertEqual(Themes.paper.cellRamp.count, 5)
        XCTAssertEqual(Themes.midnight.cellRamp.count, 5)
    }

    func testByIdResolvesAllShippingThemes() {
        XCTAssertNotNil(Themes.byId("github-light"))
        XCTAssertNotNil(Themes.byId("github-dark"))
        XCTAssertNotNil(Themes.byId("paper"))
        XCTAssertNotNil(Themes.byId("midnight"))
        XCTAssertNotNil(Themes.byId("auto"))
        XCTAssertNil(Themes.byId("nope"))
    }

    func testMidnightCarriesGradientDefs() {
        let m = Themes.midnight
        XCTAssertTrue(m.backgroundIsGradient)
        XCTAssertEqual(m.background, "url(#midnight-bg)")
        XCTAssertNotNil(m.gradientSVG)
        XCTAssertTrue(m.gradientSVG?.contains("radialGradient") ?? false)
    }

    func testAutoResolvesToLightOrDark() {
        let resolved = Themes.autoResolved()
        XCTAssertTrue(resolved.id == "github-dark" || resolved.id == "github-light")
    }

    // Stream D — round-trip a static-image PreviousWallpaper through JSON to
    // catch any future Codable drift on the on-disk format.
    func testPreviousWallpaperStaticImageJSONRoundTrip() throws {
        let original = PreviousWallpaper(
            displayUUID: "37D8832A-2D66-02CA-B9F7-8F30A301B230",
            type: .staticImage,
            imagePath: "/Users/example/Pictures/sunset.jpg"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(PreviousWallpaper.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.type, .staticImage)
        XCTAssertEqual(decoded.imagePath, "/Users/example/Pictures/sunset.jpg")
    }
}
