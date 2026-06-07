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
            path: "Sources/CodexCore"
        ),
        .target(
            name: "CodexCoreUI",
            dependencies: [
                "CodexCore",
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ],
            path: "Sources/CodexCoreUI"
        ),
        .executableTarget(
            name: "CodexRun",
            dependencies: ["CodexCore"],
            path: "Sources/CodexRun"
        ),
        .executableTarget(
            name: "CodexChatExample",
            dependencies: ["CodexCore", "CodexCoreUI"],
            path: "Examples/CodexChatExample"
        ),
        .testTarget(
            name: "CodexCoreTests",
            dependencies: ["CodexCore"],
            path: "Tests/CodexCoreTests"
        )
    ]
)
