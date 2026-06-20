// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CodexCore",
    platforms: [
        .macOS(.v26),
        .iOS(.v17)
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
            name: "codex-chat-example",
            targets: ["CodexChatExample"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.1")
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
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
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
            name: "CodexChatExample",
            dependencies: ["CodexCore", "CodexCoreUI"],
            path: "Examples/CodexChatExample",
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
