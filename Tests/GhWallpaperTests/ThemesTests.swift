import XCTest
@testable import GhWallpaper

final class ThemesTests: XCTestCase {
    func testEveryBuiltinHasFiveColorRamp() {
        XCTAssertEqual(Themes.builtins.count, 12)
        for theme in Themes.builtins {
            XCTAssertEqual(theme.cellRamp.count, 5, "theme \(theme.id) ramp wrong length")
        }
    }

    func testByIdResolvesAllShippingThemes() {
        for theme in Themes.builtins {
            XCTAssertNotNil(Themes.byId(theme.id), "byId failed for \(theme.id)")
        }
        XCTAssertNotNil(Themes.byId("auto"))
        XCTAssertNil(Themes.byId("nope"))
    }

    func testRemovedThemesNoLongerResolve() {
        // Sanity guard: sunset + forest were dropped in v0.2.0. byId should
        // miss them so the daemon's resolvedTheme() falls back to githubDark
        // for any user still on those ids.
        XCTAssertNil(Themes.byId("sunset"))
        XCTAssertNil(Themes.byId("forest"))
    }

    func testNewThemesPresent() {
        for id in ["tokyo-night", "dracula", "nord", "gruvbox-dark", "catppuccin-mocha"] {
            XCTAssertNotNil(Themes.byId(id), "expected new theme \(id) to resolve")
        }
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

    // MARK: - Custom themes

    func testCustomThemeLoadsFromJSONDirectory() throws {
        let tmp = try makeTempThemesDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let json = """
        {
          "id": "test-custom",
          "background": "#112233",
          "backgroundIsGradient": false,
          "cellRamp": ["#000000", "#333333", "#666666", "#999999", "#ffffff"],
          "headlineColor": "#ff00ff"
        }
        """
        try json.write(
            to: tmp.appendingPathComponent("test-custom.json"),
            atomically: true, encoding: .utf8
        )

        CustomThemes.shared.directoryOverride = tmp
        CustomThemes.shared.reload()
        defer {
            CustomThemes.shared.directoryOverride = nil
            CustomThemes.shared.reload()
        }

        let resolved = Themes.byId("test-custom")
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.background, "#112233")
        XCTAssertEqual(resolved?.cellRamp.count, 5)
    }

    func testCustomThemeWithBadHexIsRejected() throws {
        let tmp = try makeTempThemesDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let json = """
        {
          "id": "bad-custom",
          "background": "not-a-hex",
          "cellRamp": ["#000000", "#333333", "#666666", "#999999", "#ffffff"],
          "headlineColor": "#ff00ff"
        }
        """
        try json.write(
            to: tmp.appendingPathComponent("bad.json"),
            atomically: true, encoding: .utf8
        )

        CustomThemes.shared.directoryOverride = tmp
        CustomThemes.shared.reload()
        defer {
            CustomThemes.shared.directoryOverride = nil
            CustomThemes.shared.reload()
        }

        XCTAssertNil(Themes.byId("bad-custom"))
    }

    func testCustomThemeCannotShadowBuiltin() throws {
        let tmp = try makeTempThemesDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Same id as a built-in — should be skipped, built-in still wins.
        let json = """
        {
          "id": "github-dark",
          "background": "#ff0000",
          "cellRamp": ["#ff0000", "#ff0000", "#ff0000", "#ff0000", "#ff0000"],
          "headlineColor": "#ff0000"
        }
        """
        try json.write(
            to: tmp.appendingPathComponent("github-dark.json"),
            atomically: true, encoding: .utf8
        )

        CustomThemes.shared.directoryOverride = tmp
        CustomThemes.shared.reload()
        defer {
            CustomThemes.shared.directoryOverride = nil
            CustomThemes.shared.reload()
        }

        let resolved = Themes.byId("github-dark")
        XCTAssertEqual(resolved?.background, "#0d1117", "built-in github-dark must not be overridden")
    }

    func testHexValidator() {
        XCTAssertTrue(CustomThemes.isValidHex("#abc"))
        XCTAssertTrue(CustomThemes.isValidHex("#abcd"))
        XCTAssertTrue(CustomThemes.isValidHex("#aabbcc"))
        XCTAssertTrue(CustomThemes.isValidHex("#aabbccdd"))
        XCTAssertTrue(CustomThemes.isValidHex("#AABBCC"))
        XCTAssertFalse(CustomThemes.isValidHex("aabbcc"))      // missing #
        XCTAssertFalse(CustomThemes.isValidHex("#xyz"))         // bad chars
        XCTAssertFalse(CustomThemes.isValidHex("#aabbc"))       // 5 chars, invalid length
        XCTAssertFalse(CustomThemes.isValidHex(""))
    }

    private func makeTempThemesDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gh-wallpaper-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }
}
