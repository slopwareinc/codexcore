// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "CodexCore",
            targets: ["CodexCore"]
        ),
        .executable(
            name: "codex-run",
            targets: ["CodexRun"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CodexCore",
            dependencies: [],
            path: "Sources/CodexCore"
        ),
        .executableTarget(
            name: "CodexRun",
            dependencies: ["CodexCore"],
            path: "Sources/CodexRun"
        ),
        .testTarget(
            name: "CodexCoreTests",
            dependencies: ["CodexCore"],
            path: "Tests/CodexCoreTests"
        )
    ]
)
