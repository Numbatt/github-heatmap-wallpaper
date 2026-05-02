import Foundation

/// First-run + reconfigure flow. Re-runnable, non-destructive (pre-fills
/// current values when re-running).
public struct Wizard {
    public init() {}

    public func run() async throws -> UserConfig {
        let existing = (try? ConfigStore.read())

        printBanner()

        // Username
        let username: String = ask(
            prompt: "GitHub username",
            defaultValue: existing?.username,
            validator: { (input: String) -> String? in
                input.isEmpty ? "username required" : nil
            }
        )
        if !(await Self.usernameExists(username)) {
            print("warning: \(username) doesn't appear to exist on github.com — continuing anyway. You can re-run the wizard to fix.")
        }

        // Theme
        print("\nThemes:")
        print("  1) github-dark   2) github-light   3) paper   4) midnight   5) auto (matches macOS appearance)")
        let themeID: String = ask(
            prompt: "Theme",
            defaultValue: existing?.themeID ?? "github-dark",
            validator: { input in
                Themes.byId(input) == nil ? "unknown theme; pick one of: github-dark, github-light, paper, midnight, auto" : nil
            }
        )

        // Displays
        let displaysRaw: String = ask(
            prompt: "Displays (all, main, or 'custom:UUID1,UUID2')",
            defaultValue: existing?.displays.serialized ?? "all",
            validator: { _ in nil }
        )
        let displays = UserConfig.DisplayMode.parse(displaysRaw)

        let config = UserConfig(
            username: username,
            themeID: themeID,
            displays: displays,
            includePrivate: existing?.includePrivate ?? true
        )

        try ConfigStore.write(config)
        print("\n✓ saved \(Paths.configFile.path)")
        return config
    }

    private func printBanner() {
        print("""

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
         gh-wallpaper setup
         GitHub contribution heatmap as your macOS desktop wallpaper.
         No tokens, no signup, no telemetry.
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        """)
    }

    private func ask(
        prompt: String,
        defaultValue: String?,
        validator: (String) -> String?
    ) -> String {
        while true {
            let suffix = defaultValue.map { " [\($0)]" } ?? ""
            print("\(prompt)\(suffix): ", terminator: "")
            let raw = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
            let value = raw.isEmpty ? (defaultValue ?? "") : raw
            if let err = validator(value) {
                print("  → \(err)")
                continue
            }
            return value
        }
    }

    public static func usernameExists(_ username: String) async -> Bool {
        guard let url = URL(string: "https://github.com/\(username)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.setValue(Scraper.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }
}
