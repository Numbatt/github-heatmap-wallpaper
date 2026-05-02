import Foundation

// Entry point. Dispatches to Commands.dispatch which routes every CLI form:
//
//   gh-wallpaper                       Run setup wizard
//   gh-wallpaper <username>            One-shot render (M1 spike compatibility)
//   gh-wallpaper render | refresh | theme | pause | start | displays |
//                  diagnose | uninstall | --help | --daemon
//
// All dispatch logic lives in CLI/Commands.swift.

@main
struct GhWallpaperEntrypoint {
    static func main() async {
        let exitCode = await Commands.dispatch(CommandLine.arguments)
        exit(exitCode)
    }
}
