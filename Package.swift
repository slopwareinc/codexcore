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
        ),
        .executable(
            name: "codex-ui-gallery",
            targets: ["CodexUIGallery"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.2.9"),
        // Syntax highlighting for the Files preview pane. SwiftTreeSitter drives the
        // parse/query, and each grammar package below ships its own tree-sitter parser
        // plus a bundled `queries/highlights.scm` that LanguageConfiguration loads.
        // Curated per-grammar packages (each a few MB) are used instead of a single
        // all-languages bundle to keep the repo's clone size small.
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.9.0"),
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", branch: "with-generated-files"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", branch: "master"),
        // JavaScript/Python/YAML: pinned to tags that hardcode `sources` (scanner.c).
        // Their master/newer tags compute sources via `FileManager.fileExists(atPath:)`
        // with a relative path, which fails when SwiftPM evaluates them as nested
        // dependencies — dropping the external scanner and breaking the link.
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", branch: "master"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.23.6"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go", branch: "master"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", branch: "master"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", branch: "master"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-ruby", branch: "master"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-c", branch: "master"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-yaml", exact: "0.7.0"),
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
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterRuby", package: "tree-sitter-ruby"),
                .product(name: "TreeSitterC", package: "tree-sitter-c"),
                .product(name: "TreeSitterYAML", package: "tree-sitter-yaml"),
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
            dependencies: [
                "CodexCore",
                "CodexCoreUI",
            ],
            path: "Sources/CodexCoreApp",
            exclude: ["Info.plist", "Resources"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "CodexUIGallery",
            dependencies: ["CodexCore", "CodexCoreUI"],
            path: "Sources/CodexUIGallery",
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
            resources: [.process("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CodexCoreAppTests",
            dependencies: [
                "CodexCore",
                "CodexCoreUI",
                "CodexCoreApp",
            ],
            path: "Tests/CodexCoreAppTests",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                // SwiftPM places binary frameworks beside test bundles but only
                // adds PackageFrameworks to their runtime search paths.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."]),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
