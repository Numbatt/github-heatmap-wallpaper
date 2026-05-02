// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "gh-wallpaper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "gh-wallpaper", targets: ["GhWallpaper"])
    ],
    targets: [
        .executableTarget(
            name: "GhWallpaper",
            path: "Sources/GhWallpaper"
        ),
        .testTarget(
            name: "GhWallpaperTests",
            dependencies: ["GhWallpaper"],
            path: "Tests/GhWallpaperTests",
            resources: [.copy("fixtures")]
        )
    ]
)
