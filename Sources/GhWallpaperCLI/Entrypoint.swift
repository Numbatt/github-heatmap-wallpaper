import Dispatch
import Foundation
import GhWallpaper

// Entry point. All dispatch logic lives in the GhWallpaper library
// (Sources/GhWallpaper/CLI/Commands.swift).
//
// `main` is intentionally synchronous. The editor subcommands
// (`themes new`, `theme … --edit`) drive `NSApplication.run()` on the
// main thread; mixing that with `await MainActor.run { … }` from a
// `@main async` Swift Concurrency context starves both `DispatchQueue.main`
// and MainActor continuations, breaking the live preview and the
// post-editor wallpaper apply (see `Commands.dispatchEditorSync`).
//
// For everything else we kick a top-level `Task` and let `dispatchMain()`
// drive libdispatch on the main thread until the task `exit()`s.

@main
struct GhWallpaperEntrypoint {
    static func main() {
        let argv = CommandLine.arguments
        if Commands.isEditorInvocation(argv) {
            exit(Commands.dispatchEditorSync(argv))
        }
        Task.detached {
            let code = await Commands.dispatch(argv)
            exit(code)
        }
        dispatchMain()
    }
}
