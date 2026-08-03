import Foundation
import CodexCore

public struct CodexAgentsDocumentPolicy: Equatable, Sendable {
    public var projectDocumentMaximumBytes: Int
    public var fallbackFilenames: [String]
    public var projectRootMarkers: [String]

    public init(
        projectDocumentMaximumBytes: Int = 32 * 1_024,
        fallbackFilenames: [String] = [],
        projectRootMarkers: [String] = [".git"]
    ) {
        self.projectDocumentMaximumBytes = max(0, projectDocumentMaximumBytes)
        self.fallbackFilenames = fallbackFilenames.filter { !$0.isEmpty && $0 != "AGENTS.md" }
        self.projectRootMarkers = projectRootMarkers.filter { !$0.isEmpty }
    }

    public static let defaults = CodexAgentsDocumentPolicy()
}

public enum CodexAgentsDocumentScope: String, Equatable, Sendable {
    case global
    case project
}

public struct CodexAgentsDocumentLayer: Identifiable, Equatable, Sendable {
    public var path: String
    public var scope: CodexAgentsDocumentScope
    public var size: Int
    public var content: String
    public var isTruncated: Bool

    public var id: String { path }

    public init(
        path: String,
        scope: CodexAgentsDocumentScope,
        size: Int,
        content: String,
        isTruncated: Bool
    ) {
        self.path = path
        self.scope = scope
        self.size = size
        self.content = content
        self.isTruncated = isTruncated
    }
}

public struct CodexAgentsDocumentSnapshot: Equatable, Sendable {
    public var layers: [CodexAgentsDocumentLayer]
    public var globalPath: String
    public var globalContent: String
    public var projectRoot: String
    public var policy: CodexAgentsDocumentPolicy

    public init(
        layers: [CodexAgentsDocumentLayer],
        globalPath: String,
        globalContent: String,
        projectRoot: String,
        policy: CodexAgentsDocumentPolicy
    ) {
        self.layers = layers
        self.globalPath = globalPath
        self.globalContent = globalContent
        self.projectRoot = projectRoot
        self.policy = policy
    }
}

public protocol CodexRemoteFileSystem: Sendable {
    func directoryEntries(at path: String) async throws -> [CodexSchemaFSReadDirectoryEntry]
    func readFile(at path: String) async throws -> Data
    func writeFile(_ data: Data, at path: String) async throws
}

public actor CodexAppServerFileSystem: CodexRemoteFileSystem {
    private let codex: Codex

    public init(codex: Codex) {
        self.codex = codex
    }

    public func directoryEntries(at path: String) async throws -> [CodexSchemaFSReadDirectoryEntry] {
        try await codex.readDirectory(.init(path: Self.schemaPath(path))).entries
    }

    public func readFile(at path: String) async throws -> Data {
        let response = try await codex.readFile(.init(path: Self.schemaPath(path)))
        guard let data = Data(base64Encoded: response.dataBase64) else {
            throw CodexRemoteFileSystemError.invalidBase64(path)
        }
        return data
    }

    public func writeFile(_ data: Data, at path: String) async throws {
        _ = try await codex.writeFile(.init(
            dataBase64: data.base64EncodedString(),
            path: Self.schemaPath(path)
        ))
    }

    private static func schemaPath(_ path: String) -> CodexSchemaAbsolutePathBuf {
        CodexSchemaAbsolutePathBuf(.string(path))
    }
}

public enum CodexRemoteFileSystemError: LocalizedError, Equatable, Sendable {
    case invalidBase64(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBase64(let path):
            "The app-server returned invalid file data for \(path)."
        }
    }
}

public actor CodexAgentsDocumentStore {
    private let fileSystem: any CodexRemoteFileSystem
    private let policy: CodexAgentsDocumentPolicy

    public init(
        fileSystem: any CodexRemoteFileSystem,
        policy: CodexAgentsDocumentPolicy = .defaults
    ) {
        self.fileSystem = fileSystem
        self.policy = policy
    }

    public func resolve(codexHome: String, workingDirectory: String) async throws -> CodexAgentsDocumentSnapshot {
        let home = Self.standardized(codexHome)
        let cwd = Self.standardized(workingDirectory)
        let globalPath = Self.appending("AGENTS.md", to: home)
        var globalContent = ""
        var layers: [CodexAgentsDocumentLayer] = []

        if try await containsFile(named: "AGENTS.md", in: home) {
            let data = try await fileSystem.readFile(at: globalPath)
            globalContent = String(decoding: data, as: UTF8.self)
            layers.append(.init(
                path: globalPath,
                scope: .global,
                size: data.count,
                content: globalContent,
                isTruncated: false
            ))
        }

        let directories = try await projectDirectories(from: cwd)
        var remainingBytes = policy.projectDocumentMaximumBytes
        for directory in directories {
            guard let filename = try await documentFilename(in: directory) else { continue }
            let path = Self.appending(filename, to: directory)
            let data = try await fileSystem.readFile(at: path)
            let retainedCount = min(data.count, remainingBytes)
            let retained = data.prefix(retainedCount)
            layers.append(.init(
                path: path,
                scope: .project,
                size: data.count,
                content: String(decoding: retained, as: UTF8.self),
                isTruncated: retainedCount < data.count
            ))
            remainingBytes -= retainedCount
        }

        return CodexAgentsDocumentSnapshot(
            layers: layers,
            globalPath: globalPath,
            globalContent: globalContent,
            projectRoot: directories.first ?? cwd,
            policy: policy
        )
    }

    public func saveGlobal(content: String, codexHome: String) async throws {
        let path = Self.appending("AGENTS.md", to: Self.standardized(codexHome))
        try await fileSystem.writeFile(Data(content.utf8), at: path)
    }

    private func projectDirectories(from cwd: String) async throws -> [String] {
        var current = cwd
        var walked = [current]
        while current != "/" {
            let entries = try await fileSystem.directoryEntries(at: current)
            if entries.contains(where: { policy.projectRootMarkers.contains($0.fileName) }) {
                return walked.reversed()
            }
            let parent = Self.parent(of: current)
            guard parent != current else { break }
            current = parent
            walked.append(current)
        }
        return [cwd]
    }

    private func documentFilename(in directory: String) async throws -> String? {
        let entries = try await fileSystem.directoryEntries(at: directory)
        let files = Set(entries.lazy.filter(\.isFile).map(\.fileName))
        return (["AGENTS.md"] + policy.fallbackFilenames).first(where: files.contains)
    }

    private func containsFile(named filename: String, in directory: String) async throws -> Bool {
        try await fileSystem.directoryEntries(at: directory)
            .contains { $0.fileName == filename && $0.isFile }
    }

    private static func standardized(_ path: String) -> String {
        NSString(string: path).standardizingPath
    }

    private static func parent(of path: String) -> String {
        NSString(string: path).deletingLastPathComponent.nilIfBlank ?? "/"
    }

    private static func appending(_ component: String, to path: String) -> String {
        NSString(string: path).appendingPathComponent(component)
    }
}
