import Foundation
import XCTest
@testable import CodexCoreUI
import CodexCore

final class CodexAgentsDocumentsTests: XCTestCase {
    func testResolvesGlobalAndProjectLayersInPrecedenceOrder() async throws {
        let fileSystem = TestRemoteFileSystem(
            directories: [
                "/home/codex": [.file("AGENTS.md")],
                "/repo": [.directory(".git"), .file("AGENTS.md")],
                "/repo/Sources": [.file("INSTRUCTIONS.md")],
                "/repo/Sources/App": [.file("AGENTS.md")]
            ],
            files: [
                "/home/codex/AGENTS.md": Data("global".utf8),
                "/repo/AGENTS.md": Data("root".utf8),
                "/repo/Sources/INSTRUCTIONS.md": Data("sources".utf8),
                "/repo/Sources/App/AGENTS.md": Data("app".utf8)
            ]
        )
        let store = CodexAgentsDocumentStore(
            fileSystem: fileSystem,
            policy: .init(fallbackFilenames: ["INSTRUCTIONS.md"])
        )

        let snapshot = try await store.resolve(
            codexHome: "/home/codex",
            workingDirectory: "/repo/Sources/App"
        )

        XCTAssertEqual(snapshot.projectRoot, "/repo")
        XCTAssertEqual(snapshot.layers.map(\.path), [
            "/home/codex/AGENTS.md",
            "/repo/AGENTS.md",
            "/repo/Sources/INSTRUCTIONS.md",
            "/repo/Sources/App/AGENTS.md"
        ])
        XCTAssertEqual(snapshot.layers.map(\.content), ["global", "root", "sources", "app"])
        XCTAssertEqual(snapshot.layers.map(\.scope), [.global, .project, .project, .project])
    }

    func testProjectByteCapIsSharedAcrossLayersAndReportsOriginalSize() async throws {
        let fileSystem = TestRemoteFileSystem(
            directories: [
                "/repo": [.directory(".git"), .file("AGENTS.md")],
                "/repo/App": [.file("AGENTS.md")]
            ],
            files: [
                "/repo/AGENTS.md": Data("1234".utf8),
                "/repo/App/AGENTS.md": Data("5678".utf8)
            ]
        )
        let store = CodexAgentsDocumentStore(
            fileSystem: fileSystem,
            policy: .init(projectDocumentMaximumBytes: 6)
        )

        let snapshot = try await store.resolve(codexHome: "/home", workingDirectory: "/repo/App")

        XCTAssertEqual(snapshot.layers.map(\.content), ["1234", "56"])
        XCTAssertEqual(snapshot.layers.map(\.size), [4, 4])
        XCTAssertEqual(snapshot.layers.map(\.isTruncated), [false, true])
    }

    func testSavesGlobalLayerThroughRemoteFilesystem() async throws {
        let fileSystem = TestRemoteFileSystem(directories: [:], files: [:])
        let store = CodexAgentsDocumentStore(fileSystem: fileSystem)

        try await store.saveGlobal(content: "Be careful", codexHome: "/home/codex")

        let saved = await fileSystem.savedFile(at: "/home/codex/AGENTS.md")
        XCTAssertEqual(saved, Data("Be careful".utf8))
    }
}

final class CodexPromptLibraryTests: XCTestCase {
    func testLoadsMarkdownPromptsAndParsesFrontMatter() async throws {
        let fileSystem = TestRemoteFileSystem(
            directories: [
                "/home/codex": [.directory("prompts")],
                "/home/codex/prompts": [.file("review.md"), .file("ignored.txt")]
            ],
            files: [
                "/home/codex/prompts/review.md": Data("""
                ---
                description: Review this branch
                argument-hint: "[focus]"
                ---
                Review the changes carefully.
                """.utf8)
            ]
        )

        let prompts = try await CodexPromptLibrary(fileSystem: fileSystem).load(codexHome: "/home/codex")

        XCTAssertEqual(prompts, [
            CodexPromptLibraryEntry(
                name: "review",
                description: "Review this branch",
                argumentHint: "[focus]",
                body: "Review the changes carefully.",
                path: "/home/codex/prompts/review.md"
            )
        ])
    }

    func testMissingPromptDirectoryProducesEmptyLibrary() async throws {
        let fileSystem = TestRemoteFileSystem(directories: ["/home/codex": []], files: [:])

        let prompts = try await CodexPromptLibrary(fileSystem: fileSystem).load(codexHome: "/home/codex")

        XCTAssertEqual(prompts, [])
    }

    func testPromptCommandsIncludeUserAndMCPPrompts() {
        let prompts = [
            CodexPromptLibraryEntry(
                name: "release",
                description: "Prepare a release",
                body: "Prepare the release.",
                path: "/home/prompts/release.md"
            ),
            CodexPromptLibraryEntry(
                name: "lookup",
                description: "Look up a record",
                argumentHint: "<id>",
                body: "Look up the record.",
                source: .mcp(serverName: "CRM")
            )
        ]

        let commands = CodexSlashCommand.promptCommands(from: prompts)

        XCTAssertEqual(commands.map(\.title), ["lookup", "release"])
        XCTAssertEqual(commands.first?.section, "MCP prompts")
        XCTAssertEqual(commands.first?.scopeBadge, "CRM")
        XCTAssertEqual(commands.first?.detail, "Look up a record · <id>")
        XCTAssertEqual(commands.last?.section, "Prompts")
        XCTAssertEqual(commands.last?.draftText, "Prepare the release.")
    }
}

private actor TestRemoteFileSystem: CodexRemoteFileSystem {
    private var directories: [String: [CodexSchemaFSReadDirectoryEntry]]
    private var files: [String: Data]

    init(
        directories: [String: [CodexSchemaFSReadDirectoryEntry]],
        files: [String: Data]
    ) {
        self.directories = directories
        self.files = files
    }

    func directoryEntries(at path: String) async throws -> [CodexSchemaFSReadDirectoryEntry] {
        directories[path] ?? []
    }

    func readFile(at path: String) async throws -> Data {
        guard let data = files[path] else { throw TestFileSystemError.missing(path) }
        return data
    }

    func writeFile(_ data: Data, at path: String) async throws {
        files[path] = data
    }

    func savedFile(at path: String) -> Data? {
        files[path]
    }
}

private enum TestFileSystemError: Error {
    case missing(String)
}

private extension CodexSchemaFSReadDirectoryEntry {
    static func file(_ name: String) -> Self {
        .init(fileName: name, isDirectory: false, isFile: true)
    }

    static func directory(_ name: String) -> Self {
        .init(fileName: name, isDirectory: true, isFile: false)
    }
}
