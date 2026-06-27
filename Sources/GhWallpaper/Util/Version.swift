import Foundation

/// The version string for this binary. Update this on every release.
public let CurrentVersion = "0.2.3"

/// Brief "what's new" notes per released version. Shown once on first daemon
/// tick after an upgrade, and via `gh-wallpaper version`.
private let changelog: [String: String] = [
    "0.2.3": """
        • gh-wallpaper edit — visual editor for your active theme (no args needed)
        • gh-wallpaper <theme-name> shorthand now works for custom themes too
        • gh-wallpaper theme with no args shows current theme + full list
        • gh-wallpaper dark / light as aliases for the github-* themes
        • Unknown commands now show a clear error instead of silently failing
        """,
    "0.2.2": "• Headline customization, system fonts, and daily theme/headline rotation",
    "0.2.1": "• Linux beta: same renderer + all themes, driven by systemd timer",
]

/// Returns the changelog entry for `CurrentVersion` if `fromVersion` differs,
/// indicating the binary just upgraded. Returns nil if already up to date.
public func whatsNew(since fromVersion: String?) -> String? {
    guard fromVersion != CurrentVersion else { return nil }
    return changelog[CurrentVersion]
}

/// Returns true if semantic version string `a` is newer than `b`.
/// Strips a leading "v" prefix and compares numeric components.
public func isNewerVersion(_ a: String, than b: String) -> Bool {
    let parts: (String) -> [Int] = { s in
        s.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
         .split(separator: ".").compactMap { Int($0) }
    }
    let av = parts(a), bv = parts(b)
    for i in 0..<max(av.count, bv.count) {
        let x = i < av.count ? av[i] : 0
        let y = i < bv.count ? bv[i] : 0
        if x != y { return x > y }
    }
    return false
}
