import XCTest
@testable import GhWallpaper

/// Fixture-based tests for `HTMLParser`. Our highest-risk failure is GitHub
/// silently changing the markup of `/users/<name>/contributions`; the fixtures
/// here are committed snapshots of real responses, refreshed via
/// `script/refresh-fixtures.sh`.
///
/// Fixture sources (also encoded in `script/refresh-fixtures.sh`):
///   - `active.html` -> torvalds   (extremely dense activity, captured upstream)
///   - `sparse.html` -> mojombo    (GitHub co-founder; light recent public activity)
///   - `empty.html`  -> defunkt    (GitHub co-founder; effectively zero recent
///                                  public contributions — every cell level 0)
///
/// If GitHub's markup ever shifts, these tests fail in CI on the very next
/// commit. The Stream F live canary catches drift between commits.
final class HTMLParserTests: XCTestCase {
    private let parser = HTMLParser()

    // MARK: - Helpers

    private func loadFixture(_ name: String, file: StaticString = #file, line: UInt = #line) throws -> String {
        // Package.swift declares fixtures as `.copy("fixtures")`, so they land
        // in the bundle under a `fixtures/` subdirectory. Try both locations
        // because some toolchains flatten resources during `.copy`.
        let path = Bundle.module.path(forResource: name, ofType: "html", inDirectory: "fixtures")
                ?? Bundle.module.path(forResource: name, ofType: "html")
        let resolved = try XCTUnwrap(path, "fixture \(name).html not found in test bundle", file: file, line: line)
        return try String(contentsOfFile: resolved, encoding: .utf8)
    }

    private func assertISODate(_ iso: String, file: StaticString = #file, line: UInt = #line) {
        let parts = iso.split(separator: "-")
        XCTAssertEqual(parts.count, 3, "bad ISO date: \(iso)", file: file, line: line)
        guard parts.count == 3 else { return }
        XCTAssertEqual(parts[0].count, 4, "bad year in \(iso)", file: file, line: line)
        XCTAssertEqual(parts[1].count, 2, "bad month in \(iso)", file: file, line: line)
        XCTAssertEqual(parts[2].count, 2, "bad day in \(iso)", file: file, line: line)
        XCTAssertNotNil(Int(parts[0]), file: file, line: line)
        XCTAssertNotNil(Int(parts[1]), file: file, line: line)
        XCTAssertNotNil(Int(parts[2]), file: file, line: line)
    }

    // MARK: - Fixture: active

    func testParsesActiveFixture() throws {
        let html = try loadFixture("active")
        let days = try parser.parse(html: html)

        // GitHub typically returns 53 columns x 7 rows = 371 cells (some weeks
        // are partially empty at edges). Allow some give-and-take.
        XCTAssertLessThanOrEqual(days.count, 371, "should never exceed one year of cells")
        XCTAssertGreaterThanOrEqual(days.count, 350, "active fixture should be near-full year")

        // Sorted oldest -> newest, no duplicates.
        for i in 1..<days.count {
            XCTAssertLessThan(days[i - 1].isoDate, days[i].isoDate, "days must be strictly chronological")
        }

        for d in days {
            assertISODate(d.isoDate)
            XCTAssertTrue((0...4).contains(d.level), "level out of range: \(d.level) on \(d.isoDate)")
        }

        let nonZero = days.filter { $0.level > 0 }.count
        let pct = Double(nonZero) / Double(days.count)
        XCTAssertGreaterThanOrEqual(pct, 0.5,
            "active fixture should have >=50% non-zero days; got \(pct) (\(nonZero)/\(days.count))")
    }

    // MARK: - Fixture: sparse

    func testParsesSparseFixture() throws {
        let html = try loadFixture("sparse")
        let days = try parser.parse(html: html)

        XCTAssertLessThanOrEqual(days.count, 371)
        XCTAssertGreaterThanOrEqual(days.count, 350)

        for d in days {
            assertISODate(d.isoDate)
            XCTAssertTrue((0...4).contains(d.level), "level out of range: \(d.level) on \(d.isoDate)")
        }

        let zero = days.filter { $0.level == 0 }.count
        let pct = Double(zero) / Double(days.count)
        XCTAssertGreaterThanOrEqual(pct, 0.8,
            "sparse fixture should have >=80% zero days; got \(pct) (\(zero)/\(days.count))")
    }

    // MARK: - Fixture: empty

    func testParsesEmptyFixture() throws {
        let html = try loadFixture("empty")

        // Two acceptable behaviours:
        //   1. The page returns a full grid of all-zero cells -> parser succeeds
        //      and every level == 0.
        //   2. The page returns no grid at all (e.g. ghost/deactivated account)
        //      -> parser throws ScraperError.parseError. We assert the failure
        //      mode is graceful.
        do {
            let days = try parser.parse(html: html)
            XCTAssertGreaterThan(days.count, 0,
                "if parser succeeded it must have found cells; otherwise it should have thrown")
            for d in days {
                assertISODate(d.isoDate)
                XCTAssertEqual(d.level, 0,
                    "empty fixture must have only level-0 cells; saw \(d.level) on \(d.isoDate)")
            }
        } catch let ScraperError.parseError(msg) {
            // Acceptable: the captured account had no grid at all.
            XCTAssertFalse(msg.isEmpty, "parseError message should be non-empty")
        } catch {
            XCTFail("expected ScraperError.parseError or success, got: \(error)")
        }
    }

    // MARK: - Synthetic well-formed input

    func testParsesSyntheticThreeCellSnippet() throws {
        // Note: cells are intentionally given out-of-order in the source HTML
        // to verify the parser sorts them chronologically. The middle cell
        // also reverses the data-level / data-date attribute order to exercise
        // the parser's altPattern branch.
        let html = """
        <html><body>
        <table>
          <tr>
            <td class="ContributionCalendar-day" data-date="2025-01-03" data-level="2">Jan 3</td>
            <td class="ContributionCalendar-day" data-date="2025-01-01" data-level="0">Jan 1</td>
            <td class="ContributionCalendar-day" data-level="4" data-date="2025-01-02">Jan 2</td>
          </tr>
        </table>
        </body></html>
        """

        let days = try parser.parse(html: html)
        XCTAssertEqual(days.count, 3)
        XCTAssertEqual(days.map { $0.isoDate }, ["2025-01-01", "2025-01-02", "2025-01-03"])
        XCTAssertEqual(days.map { $0.level }, [0, 4, 2])

        // Spot-check the parsed Date for one cell (UTC midnight).
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        XCTAssertEqual(days[0].date, formatter.date(from: "2025-01-01"))
    }

    // MARK: - Malformed input

    func testThrowsOnMissingDataLevel() {
        // Cell is missing data-level entirely. Parser should find no usable
        // cells and throw ScraperError.parseError.
        let html = """
        <html><body>
        <td class="ContributionCalendar-day" data-date="2025-01-01">no level</td>
        <td class="ContributionCalendar-day" data-date="2025-01-02">no level either</td>
        </body></html>
        """

        XCTAssertThrowsError(try parser.parse(html: html)) { error in
            guard case ScraperError.parseError = error else {
                XCTFail("expected ScraperError.parseError, got \(error)")
                return
            }
        }
    }

    func testThrowsOnEmptyHTML() {
        XCTAssertThrowsError(try parser.parse(html: "")) { error in
            guard case ScraperError.parseError = error else {
                XCTFail("expected ScraperError.parseError, got \(error)")
                return
            }
        }
    }
}
