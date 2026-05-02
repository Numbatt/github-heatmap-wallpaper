import Foundation

/// Extracts contribution days from GitHub's `/users/<name>/contributions` HTML.
///
/// We do not pull in a full HTML parsing library. The contribution endpoint's
/// markup is narrow enough that a regex over the `<td class="ContributionCalendar-day"
/// ... data-date="..." ... data-level="...">` form is reliable, and adding an HTML
/// parser would balloon the binary for one regex's worth of work.
///
/// If GitHub ever changes the markup shape (e.g., switches back to inline SVG),
/// the canary CI job (.github/workflows/canary.yml) will catch it within ~24h.
public struct HTMLParser: Sendable {
    public init() {}

    public func parse(html: String) throws -> [ContributionDay] {
        // Match <td ...>...</td> blocks that carry both data-date and data-level.
        // Attribute order isn't guaranteed, so we match each attribute independently
        // within the same <td ...> opening tag.
        let pattern = #"<td\b[^>]*?\bdata-date="(\d{4}-\d{2}-\d{2})"[^>]*?\bdata-level="([0-4])"[^>]*?>"#
        let altPattern = #"<td\b[^>]*?\bdata-level="([0-4])"[^>]*?\bdata-date="(\d{4}-\d{2}-\d{2})"[^>]*?>"#

        let regexes = [
            try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
            try NSRegularExpression(pattern: altPattern, options: [.dotMatchesLineSeparators])
        ]

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]

        // Use a dict keyed by ISO date so we don't double-count when both regexes match.
        var byDate: [String: ContributionDay] = [:]
        let nsHTML = html as NSString
        let range = NSRange(location: 0, length: nsHTML.length)

        for (idx, regex) in regexes.enumerated() {
            let dateGroupIdx = (idx == 0) ? 1 : 2
            let levelGroupIdx = (idx == 0) ? 2 : 1

            regex.enumerateMatches(in: html, options: [], range: range) { match, _, _ in
                guard let match = match,
                      let dateRange = Range(match.range(at: dateGroupIdx), in: html),
                      let levelRange = Range(match.range(at: levelGroupIdx), in: html) else {
                    return
                }
                let iso = String(html[dateRange])
                let levelStr = String(html[levelRange])
                guard let level = Int(levelStr), (0...4).contains(level) else { return }
                guard let date = formatter.date(from: iso) else { return }
                byDate[iso] = ContributionDay(date: date, level: level, isoDate: iso)
            }
        }

        if byDate.isEmpty {
            throw ScraperError.parseError(
                "no <td.ContributionCalendar-day> cells with data-date+data-level found; markup may have changed"
            )
        }

        return byDate.values.sorted { $0.isoDate < $1.isoDate }
    }
}
