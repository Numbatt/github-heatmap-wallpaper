import XCTest
@testable import GhWallpaper

final class CaptureRestoreTests: XCTestCase {
    /// Round-trip a static-image PreviousWallpaper through JSON to
    /// catch any future Codable drift on the on-disk format.
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
