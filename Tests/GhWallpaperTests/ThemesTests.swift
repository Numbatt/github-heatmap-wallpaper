import XCTest
@testable import GhWallpaper

final class ThemesTests: XCTestCase {
    func testThemesContainExpectedRamps() {
        XCTAssertEqual(Themes.githubDark.cellRamp.count, 5)
        XCTAssertEqual(Themes.githubLight.cellRamp.count, 5)
        XCTAssertEqual(Themes.paper.cellRamp.count, 5)
        XCTAssertEqual(Themes.midnight.cellRamp.count, 5)
        XCTAssertEqual(Themes.catppuccinFrappe.cellRamp.count, 5)
    }

    func testByIdResolvesAllShippingThemes() {
        XCTAssertNotNil(Themes.byId("github-light"))
        XCTAssertNotNil(Themes.byId("github-dark"))
        XCTAssertNotNil(Themes.byId("paper"))
        XCTAssertNotNil(Themes.byId("midnight"))
        XCTAssertNotNil(Themes.byId("catppuccin-frappe"))
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
}
