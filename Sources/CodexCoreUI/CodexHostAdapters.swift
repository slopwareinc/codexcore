import Foundation
import SwiftUI

public protocol CodexClipboardService: Sendable {
    func copy(_ text: String)
}

public struct CodexTranscriptFileReference: Sendable, Equatable, Hashable {
    public var path: String
    public var line: Int?
    public var column: Int?

    public init(path: String, line: Int? = nil, column: Int? = nil) {
        self.path = path
        self.line = line
        self.column = column
    }
}

public struct CodexResolvedTranscriptFileReference: Sendable, Equatable, Hashable {
    public var reference: CodexTranscriptFileReference
    public var fileURL: URL

    public init(reference: CodexTranscriptFileReference, fileURL: URL) {
        self.reference = reference
        self.fileURL = fileURL
    }
}

/// Host-owned workspace scope and file-navigation actions used by transcript citations.
public protocol CodexTranscriptFileNavigationService: Sendable {
    @MainActor
    func resolve(_ reference: CodexTranscriptFileReference) -> CodexResolvedTranscriptFileReference?
    @MainActor
    func open(_ reference: CodexResolvedTranscriptFileReference)
    @MainActor
    func reveal(_ reference: CodexResolvedTranscriptFileReference)
}

public protocol CodexStringListPreferenceStore: Sendable {
    func loadStrings(forKey key: String) -> [String]
    func saveStrings(_ strings: [String], forKey key: String)
    func hasStrings(forKey key: String) -> Bool
}

public struct CodexNoopClipboardService: CodexClipboardService {
    public init() {}

    public func copy(_ text: String) {}
}

public struct CodexNoopTranscriptFileNavigationService: CodexTranscriptFileNavigationService {
    public init() {}

    public func resolve(
        _ reference: CodexTranscriptFileReference
    ) -> CodexResolvedTranscriptFileReference? { nil }

    public func open(_ reference: CodexResolvedTranscriptFileReference) {}
    public func reveal(_ reference: CodexResolvedTranscriptFileReference) {}
}

/// A workspace-bounded resolver whose actual open and reveal behavior remains host-owned.
public struct CodexWorkspaceTranscriptFileNavigationService: CodexTranscriptFileNavigationService {
    private let workspaceURL: URL
    private let fileExists: @MainActor @Sendable (URL) -> Bool
    private let openFile: @MainActor @Sendable (CodexResolvedTranscriptFileReference) -> Void
    private let revealFile: @MainActor @Sendable (CodexResolvedTranscriptFileReference) -> Void

    public init(
        workspaceURL: URL,
        fileExists: @escaping @MainActor @Sendable (URL) -> Bool = {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        },
        openFile: @escaping @MainActor @Sendable (CodexResolvedTranscriptFileReference) -> Void,
        revealFile: @escaping @MainActor @Sendable (CodexResolvedTranscriptFileReference) -> Void
    ) {
        self.workspaceURL = workspaceURL.standardizedFileURL
        self.fileExists = fileExists
        self.openFile = openFile
        self.revealFile = revealFile
    }

    public func resolve(
        _ reference: CodexTranscriptFileReference
    ) -> CodexResolvedTranscriptFileReference? {
        guard !reference.path.isEmpty, !reference.path.contains("\0") else { return nil }
        let candidate = reference.path.hasPrefix("/")
            ? URL(fileURLWithPath: reference.path)
            : workspaceURL.appending(path: reference.path)
        let resolved = candidate.standardizedFileURL
        let workspacePath = workspaceURL.path.hasSuffix("/")
            ? workspaceURL.path
            : workspaceURL.path + "/"
        guard resolved.path == workspaceURL.path || resolved.path.hasPrefix(workspacePath),
              fileExists(resolved) else { return nil }
        return CodexResolvedTranscriptFileReference(reference: reference, fileURL: resolved)
    }

    public func open(_ reference: CodexResolvedTranscriptFileReference) {
        openFile(reference)
    }

    public func reveal(_ reference: CodexResolvedTranscriptFileReference) {
        revealFile(reference)
    }
}

public struct CodexNoopStringListPreferenceStore: CodexStringListPreferenceStore {
    public init() {}

    public func loadStrings(forKey key: String) -> [String] { [] }
    public func saveStrings(_ strings: [String], forKey key: String) {}
    public func hasStrings(forKey key: String) -> Bool { false }
}

private struct CodexClipboardServiceKey: EnvironmentKey {
    static let defaultValue: any CodexClipboardService = CodexNoopClipboardService()
}

private struct CodexTranscriptFileNavigationServiceKey: EnvironmentKey {
    static let defaultValue: any CodexTranscriptFileNavigationService =
        CodexNoopTranscriptFileNavigationService()
}

public extension EnvironmentValues {
    var codexClipboardService: any CodexClipboardService {
        get { self[CodexClipboardServiceKey.self] }
        set { self[CodexClipboardServiceKey.self] = newValue }
    }

    var codexTranscriptFileNavigationService: any CodexTranscriptFileNavigationService {
        get { self[CodexTranscriptFileNavigationServiceKey.self] }
        set { self[CodexTranscriptFileNavigationServiceKey.self] = newValue }
    }
}

public extension View {
    func codexClipboardService(_ service: any CodexClipboardService) -> some View {
        environment(\.codexClipboardService, service)
    }

    func codexTranscriptFileNavigationService(
        _ service: any CodexTranscriptFileNavigationService
    ) -> some View {
        environment(\.codexTranscriptFileNavigationService, service)
    }
}
