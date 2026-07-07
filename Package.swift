// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CodexCore",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "CodexCore",
            targets: ["CodexCore"]
        ),
        .library(
            name: "CodexCoreUI",
            targets: ["CodexCoreUI"]
        ),
        .executable(
            name: "codex-run",
            targets: ["CodexRun"]
        ),
        .executable(
            name: "codex-core-app",
            targets: ["CodexCoreApp"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.2.9"),
    ],
    targets: [
        .target(
            name: "CodexCore",
            dependencies: [],
            path: "Sources/CodexCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CodexCoreUI",
            dependencies: [
                "CodexCore",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ],
            path: "Sources/CodexCoreUI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "CodexRun",
            dependencies: ["CodexCore"],
            path: "Sources/CodexRun",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "CodexCoreApp",
            dependencies: ["CodexCore", "CodexCoreUI"],
            path: "Sources/CodexCoreApp",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CodexCoreTests",
            dependencies: ["CodexCore"],
            path: "Tests/CodexCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CodexCoreUITests",
            dependencies: ["CodexCore", "CodexCoreUI"],
            path: "Tests/CodexCoreUITests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ],
    swiftLanguageModes: [.v6]
)
