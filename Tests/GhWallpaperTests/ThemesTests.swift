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

    /// Regression: the daemon is long-lived and CustomThemes caches for the
    /// process lifetime, so it re-scans on every refresh via `reload()`. This
    /// guards the contract that a `reload()` surfaces on-disk edits (an edited
    /// custom theme's new colors) and creations (a newly-added file). Without
    /// the daemon's per-tick reload, an edited custom theme kept rendering its
    /// stale startup colors and a new one fell back to github-dark.
    func testReloadPicksUpEditsAndCreations() throws {
        let tmp = try makeTempThemesDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        CustomThemes.shared.directoryOverride = tmp
        CustomThemes.shared.reload()
        defer {
            CustomThemes.shared.directoryOverride = nil
            CustomThemes.shared.reload()
        }

        let file = tmp.appendingPathComponent("blue.json")
        func writeTheme(headline: String) throws {
            try """
            {
              "id": "blue",
              "background": "#112233",
              "backgroundIsGradient": false,
              "cellRamp": ["#000000", "#333333", "#666666", "#999999", "#ffffff"],
              "headlineColor": "\(headline)"
            }
            """.write(to: file, atomically: true, encoding: .utf8)
        }

        // Starts absent: a cached empty scan must not mask a later creation.
        XCTAssertNil(Themes.byId("blue"))

        // Creation surfaces after reload (daemon's per-tick behavior).
        try writeTheme(headline: "#ff00ff")
        CustomThemes.shared.reload()
        XCTAssertEqual(Themes.byId("blue")?.headlineColor, "#ff00ff")

        // Edit surfaces after reload — the actual "resets back to old colors" bug.
        try writeTheme(headline: "#00ffff")
        CustomThemes.shared.reload()
        XCTAssertEqual(Themes.byId("blue")?.headlineColor, "#00ffff")
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

    func testCustomThemeWithImageBackgroundLoads() throws {
        let tmp = try makeTempThemesDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Create a small image fixture so validation can confirm it exists.
        let imagesDir = tmp.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        let imageURL = imagesDir.appendingPathComponent("bg.png")
        // Single-pixel PNG, just to satisfy the file-exists check + extension.
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: imageURL)

        let json = """
        {
          "id": "photo",
          "background": "#000000",
          "cellRamp": ["#111111", "#222222", "#444444", "#888888", "#ffffff"],
          "headlineColor": "#ffffff",
          "backgroundImagePath": "images/bg.png",
          "backgroundDimAlpha": 0.6
        }
        """
        try json.write(
            to: tmp.appendingPathComponent("photo.json"),
            atomically: true, encoding: .utf8
        )

        CustomThemes.shared.directoryOverride = tmp
        CustomThemes.shared.reload()
        defer {
            CustomThemes.shared.directoryOverride = nil
            CustomThemes.shared.reload()
        }

        let resolved = Themes.byId("photo")
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.backgroundImagePath, imageURL.standardizedFileURL.path)
        XCTAssertEqual(resolved?.backgroundDimAlpha, 0.6)
    }

    func testCustomThemeWithMissingImageIsRejected() throws {
        let tmp = try makeTempThemesDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let json = """
        {
          "id": "ghost-photo",
          "background": "#000000",
          "cellRamp": ["#111111", "#222222", "#444444", "#888888", "#ffffff"],
          "headlineColor": "#ffffff",
          "backgroundImagePath": "images/does-not-exist.png"
        }
        """
        try json.write(
            to: tmp.appendingPathComponent("ghost.json"),
            atomically: true, encoding: .utf8
        )

        CustomThemes.shared.directoryOverride = tmp
        CustomThemes.shared.reload()
        defer {
            CustomThemes.shared.directoryOverride = nil
            CustomThemes.shared.reload()
        }

        XCTAssertNil(Themes.byId("ghost-photo"))
    }

    func testCustomThemeBackgroundIsGradientDefaultsFalse() throws {
        // The decoder must tolerate hand-authored JSON that omits
        // `backgroundIsGradient` — earlier versions of the loader required
        // it explicitly, which broke the README example.
        let tmp = try makeTempThemesDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let json = """
        {
          "id": "minimal",
          "background": "#112233",
          "cellRamp": ["#000000", "#333333", "#666666", "#999999", "#ffffff"],
          "headlineColor": "#ff00ff"
        }
        """
        try json.write(
            to: tmp.appendingPathComponent("minimal.json"),
            atomically: true, encoding: .utf8
        )

        CustomThemes.shared.directoryOverride = tmp
        CustomThemes.shared.reload()
        defer {
            CustomThemes.shared.directoryOverride = nil
            CustomThemes.shared.reload()
        }

        let resolved = Themes.byId("minimal")
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.backgroundIsGradient, false)
    }

    func testCustomThemeSaveRoundTrip() throws {
        let tmp = try makeTempThemesDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        CustomThemes.shared.directoryOverride = tmp
        defer {
            CustomThemes.shared.directoryOverride = nil
            CustomThemes.shared.reload()
        }

        let theme = Theme(
            id: "round-trip",
            background: "#101010",
            backgroundIsGradient: false,
            cellRamp: ["#111111", "#222222", "#333333", "#444444", "#555555"],
            headlineColor: "#aabbcc"
        )
        let url = try CustomThemes.shared.save(theme)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let resolved = Themes.byId("round-trip")
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.background, "#101010")
        XCTAssertEqual(resolved?.headlineColor, "#aabbcc")
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
