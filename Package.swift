// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "gh-wallpaper",
    platforms: [.macOS("14.0")],
    products: [
        .executable(name: "gh-wallpaper", targets: ["GhWallpaperCLI"])
    ],
    targets: [
        // Library containing all the actual implementation: scraper, render,
        // daemon, capture/restore, config, etc. The CLI shell and the
        // snapshot-generator developer tool both link against this.
        .target(
            name: "GhWallpaper",
            path: "Sources/GhWallpaper"
        ),
        // Thin executable that wires `@main` to `Commands.dispatch`. All
        // logic lives in the GhWallpaper library.
        .executableTarget(
            name: "GhWallpaperCLI",
            dependencies: ["GhWallpaper"],
            path: "Sources/GhWallpaperCLI"
        ),
        // Developer tool: generates the SVG fixtures consumed by
        // SVGSnapshotTests. Not shipped to users — invoked manually via
        // `swift run snapshot-gen` (or `script/refresh-snapshots.sh`)
        // when an intentional layout change requires regenerating snapshots.
        .executableTarget(
            name: "SnapshotGen",
            dependencies: ["GhWallpaper"],
            path: "Sources/SnapshotGen"
        ),
        .testTarget(
            name: "GhWallpaperTests",
            dependencies: ["GhWallpaper"],
            path: "Tests/GhWallpaperTests",
            resources: [
                .copy("fixtures"),
                .copy("snapshots")
            ]
        )
    ]
)
