import Foundation

// Entry point. All dispatch logic lives in CLI/Commands.swift.

@main
struct GhWallpaperEntrypoint {
    static func main() async {
        let exitCode = await Commands.dispatch(CommandLine.arguments)
        exit(exitCode)
    }
}
