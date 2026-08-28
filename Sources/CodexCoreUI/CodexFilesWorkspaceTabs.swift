import Foundation
import SwiftUI

/// Stable identity for a workspace file at an optional source-control ref.
/// Paths are standardized once at the seam; callers can safely use `id` as a
/// tab resource key without carrying URL normalization rules themselves.
public struct CodexWorkspaceFileReference: Codable, Hashable, Identifiable, Sendable {
    public let fileURL: URL
    public let ref: String?

    public init(fileURL: URL, ref: String? = nil) {
        self.fileURL = fileURL.standardizedFileURL
        let normalizedRef = ref?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.ref = normalizedRef?.isEmpty == true ? nil : normalizedRef
    }

    public var id: String {
        Self.identity(fileURL: fileURL, ref: ref)
    }

    public var displayName: String {
        let name = fileURL.lastPathComponent
        guard let ref, !ref.isEmpty else { return name }
        return "\(name)@\(ref)"
    }

    public static func identity(fileURL: URL, ref: String?) -> String {
        let normalized = fileURL.standardizedFileURL.path
        let normalizedRef = ref?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "codex-file:\(normalizedRef)|\(normalized)"
    }
}

/// Presentation-only state retained by a file preview tab. The file contents
/// remain a runtime projection; only the user's find and line-location intent
/// crosses the durable workspace-tab seam.
public struct CodexFilePreviewTabState: Codable, Hashable, Sendable {
    public var searchQuery: String
    public var goToLine: Int?
    public var selectedMatch: Int

    public init(
        searchQuery: String = "",
        goToLine: Int? = nil,
        selectedMatch: Int = 0
    ) {
        self.searchQuery = searchQuery
        self.goToLine = goToLine
        self.selectedMatch = max(0, selectedMatch)
    }

    public init(tabState: CodexWorkspaceTabState) {
        self = (try? JSONDecoder().decode(Self.self, from: tabState.data)) ?? Self()
    }

    public var tabState: CodexWorkspaceTabState {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return .init(data: (try? encoder.encode(self)) ?? Data())
    }
}

/// The workspace-tab adapter for the Files browser. The browser session is a
/// retained resource host; tab identity and panel placement remain owned by
/// `CodexWorkspaceTabs`.
@MainActor
package struct CodexFilesWorkspaceTabAdapter: CodexWorkspaceTabAdapter {
    package static let adapterID = "codex.files"
    package static let routeVersion = 1

    package let session: CodexFilesSession
    private let onOpenFile: @MainActor (URL) -> Void
    private let onClose: @MainActor () -> Void

    package init(
        session: CodexFilesSession,
        onOpenFile: @escaping @MainActor (URL) -> Void = { _ in },
        onClose: @escaping @MainActor () -> Void = {}
    ) {
        self.session = session
        self.onOpenFile = onOpenFile
        self.onClose = onClose
    }

    package init(
        workspaceURL: URL,
        onOpenFile: @escaping @MainActor (URL) -> Void = { _ in },
        onClose: @escaping @MainActor () -> Void = {}
    ) {
        self.init(
            session: CodexFilesSession(rootURL: workspaceURL),
            onOpenFile: onOpenFile,
            onClose: onClose
        )
    }

    package init?(
        route: CodexWorkspaceTabRoute,
        onOpenFile: @escaping @MainActor (URL) -> Void = { _ in },
        onClose: @escaping @MainActor () -> Void = {}
    ) {
        guard route.adapterID == Self.adapterID, route.version == Self.routeVersion else {
            return nil
        }
        self.init(
            workspaceURL: URL(fileURLWithPath: route.resourceID),
            onOpenFile: onOpenFile,
            onClose: onClose
        )
    }

    package var workspaceTabRegistration: CodexWorkspaceTabRegistration {
        CodexWorkspaceTabRegistration(
            resourceKey: Self.resourceKey(for: session.rootURL),
            title: session.title,
            systemImage: "folder",
            durableRoute: .init(
                adapterID: Self.adapterID,
                version: Self.routeVersion,
                resourceID: session.rootURL.path
            ),
            onClose: onClose
        ) { context in
            AnyView(
                CodexFilesToolView(session: session) { url in
                    context.interact()
                    onOpenFile(url)
                }
            )
        }
    }

    package static func resourceKey(for workspaceURL: URL) -> String {
        "\(adapterID):\(workspaceURL.standardizedFileURL.path)"
    }

    package static func route(for workspaceURL: URL) -> CodexWorkspaceTabRoute {
        .init(
            adapterID: adapterID,
            version: routeVersion,
            resourceID: workspaceURL.standardizedFileURL.path
        )
    }
}

/// The replaceable text-file preview adapter. Every file/ref pair gets a
/// stable resource key; the preview remains non-durable until interaction pins
/// it through the workspace-tab reducer.
@MainActor
package struct CodexFilePreviewWorkspaceTabAdapter: CodexWorkspaceTabAdapter {
    package static let adapterID = "codex.file.preview"
    package static let routeVersion = 1

    package let file: CodexWorkspaceFileReference

    package init(file: CodexWorkspaceFileReference) {
        self.file = file
    }

    package init(fileURL: URL, ref: String? = nil) {
        self.init(file: .init(fileURL: fileURL, ref: ref))
    }

    package init?(route: CodexWorkspaceTabRoute) {
        guard route.adapterID == Self.adapterID, route.version == Self.routeVersion else {
            return nil
        }
        if let decoded = try? JSONDecoder().decode(CodexWorkspaceFileReference.self, from: route.payload) {
            self.file = decoded
        } else {
            // Version-one routes from the first Files slice use the resource
            // id as the canonical identity and carry no payload.
            let identity = route.resourceID.hasPrefix("codex-file:")
                ? String(route.resourceID.dropFirst("codex-file:".count))
                : route.resourceID
            let parts = identity.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let ref = parts.first.map(String.init)
            let path = parts.count > 1 ? String(parts[1]) : identity
            self.file = .init(fileURL: URL(fileURLWithPath: path), ref: ref?.isEmpty == true ? nil : ref)
        }
    }

    package var workspaceTabRegistration: CodexWorkspaceTabRegistration {
        CodexWorkspaceTabRegistration(
            resourceKey: Self.resourceKey(for: file),
            title: file.displayName,
            systemImage: "doc.text",
            lifetime: .preview,
            retentionPolicy: .activeOnly,
            pinsOnInteraction: true,
            durableRoute: Self.route(for: file),
            initialState: CodexFilePreviewTabState().tabState
        ) { context in
            AnyView(
                CodexFilePreviewView(
                    file: file,
                    tabState: context.state,
                    onInteraction: context.interact
                )
            )
        }
    }

    package static func resourceKey(for file: CodexWorkspaceFileReference) -> String {
        "\(adapterID):\(file.id)"
    }

    package static func route(for file: CodexWorkspaceFileReference) -> CodexWorkspaceTabRoute {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return .init(
            adapterID: adapterID,
            version: routeVersion,
            resourceID: file.id,
            payload: (try? encoder.encode(file)) ?? Data()
        )
    }
}
