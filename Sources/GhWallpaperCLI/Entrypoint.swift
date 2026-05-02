import Foundation
import GhWallpaper

// Entry point. All dispatch logic lives in the GhWallpaper library
// (Sources/GhWallpaper/CLI/Commands.swift).

@main
struct GhWallpaperEntrypoint {
    static func main() async {
        let exitCode = await Commands.dispatch(CommandLine.arguments)
        exit(exitCode)
    }
}
