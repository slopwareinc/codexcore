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

package enum CodexWorkspaceFileRouteValidation {
    package static func directory(
        at path: String,
        within workspaceURL: URL
    ) -> URL? {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey])
        guard contained(candidate, in: workspaceURL), values?.isDirectory == true else {
            return nil
        }
        return candidate
    }

    package static func regularFile(
        _ fileURL: URL,
        within workspaceURL: URL
    ) -> Bool {
        guard contained(fileURL, in: workspaceURL) else { return false }
        let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        return values?.isDirectory == false && values?.isRegularFile == true
    }

    private static func contained(_ candidate: URL, in workspaceURL: URL) -> Bool {
        let root = workspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
        let path = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        return path == root || path.hasPrefix(root + "/")
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

    package init?(
        restoring route: CodexWorkspaceTabRoute,
        within workspaceURL: URL,
        onOpenFile: @escaping @MainActor (URL) -> Void = { _ in },
        onClose: @escaping @MainActor () -> Void = {}
    ) {
        guard route.adapterID == Self.adapterID,
              route.version == Self.routeVersion,
              let root = CodexWorkspaceFileRouteValidation.directory(
                at: route.resourceID,
                within: workspaceURL
              ) else {
            return nil
        }
        self.init(workspaceURL: root, onOpenFile: onOpenFile, onClose: onClose)
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
        ) { _ in
            AnyView(
                CodexFilesToolView(session: session) { url in
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
        if route.payload.isEmpty {
            // Version-one routes from the first Files slice use the resource
            // id as the canonical identity and carry no payload.
            let identity = route.resourceID.hasPrefix("codex-file:")
                ? String(route.resourceID.dropFirst("codex-file:".count))
                : route.resourceID
            let parts = identity.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let ref = parts.first.map(String.init)
            let path = parts.count > 1 ? String(parts[1]) : identity
            self.file = .init(fileURL: URL(fileURLWithPath: path), ref: ref?.isEmpty == true ? nil : ref)
        } else {
            guard let decoded = try? JSONDecoder().decode(CodexWorkspaceFileReference.self, from: route.payload),
                  decoded.id == route.resourceID else {
                return nil
            }
            self.file = decoded
        }
    }

    package init?(resourceKey: String) {
        let prefix = "\(Self.adapterID):"
        guard resourceKey.hasPrefix(prefix) else { return nil }
        let rawIdentity = String(resourceKey.dropFirst(prefix.count))
        let identity = rawIdentity.hasPrefix("codex-file:")
            ? String(rawIdentity.dropFirst("codex-file:".count))
            : rawIdentity
        let parts = identity.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let ref = parts.first.map(String.init)
        let path = parts.count > 1 ? String(parts[1]) : identity
        self.init(
            file: .init(
                fileURL: URL(fileURLWithPath: path),
                ref: ref?.isEmpty == true ? nil : ref
            )
        )
    }

    package init?(
        restoring resourceKey: String,
        within workspaceURL: URL
    ) {
        guard let adapter = Self(resourceKey: resourceKey),
              adapter.file.ref == nil,
              CodexWorkspaceFileRouteValidation.regularFile(
                adapter.file.fileURL,
                within: workspaceURL
              ) else {
            return nil
        }
        self = adapter
    }

    package init?(
        restoring route: CodexWorkspaceTabRoute,
        within workspaceURL: URL
    ) {
        guard let adapter = Self(route: route),
              adapter.file.ref == nil,
              CodexWorkspaceFileRouteValidation.regularFile(
                adapter.file.fileURL,
                within: workspaceURL
              ) else {
            return nil
        }
        self = adapter
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
        ) { state in
            AnyView(
                CodexFilePreviewView(
                    file: file,
                    tabState: state
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

package struct CodexFilesWorkspaceTabAdapterSet {
    package let filesSession: CodexFilesSession?
    package let adapters: [any CodexWorkspaceTabAdapter]
}

/// Restores all Files-owned routes in one place. The chat workspace only asks
/// this registry for adapters; it never interprets route IDs or filesystem
/// availability itself.
@MainActor
package enum CodexFilesWorkspaceTabAdapterRegistry {
    package static func make(
        snapshot: CodexWorkspaceTabSnapshot,
        workspaceURL: URL,
        existingSession: CodexFilesSession?,
        onOpenFile: @escaping @MainActor (URL) -> Void,
        onSessionClosed: @escaping @MainActor (CodexFilesSession) -> Void
    ) -> CodexFilesWorkspaceTabAdapterSet {
        var adapters: [any CodexWorkspaceTabAdapter] = []
        var fileRoots = Set<String>()
        var previewKeys = Set<String>()
        var filesSession: CodexFilesSession?

        func addFiles(_ session: CodexFilesSession) {
            guard fileRoots.insert(session.rootURL.path).inserted else { return }
            if filesSession == nil { filesSession = session }
            adapters.append(CodexFilesWorkspaceTabAdapter(
                session: session,
                onOpenFile: onOpenFile,
                onClose: { onSessionClosed(session) }
            ))
        }

        if let existingSession,
           CodexWorkspaceFileRouteValidation.directory(
               at: existingSession.rootURL.path,
               within: workspaceURL
           ) != nil {
            addFiles(existingSession)
        }

        for instance in snapshot.instances {
            if let route = instance.durableRoute {
                if route.adapterID == CodexFilesWorkspaceTabAdapter.adapterID,
                   let adapter = CodexFilesWorkspaceTabAdapter(
                       restoring: route,
                       within: workspaceURL
                   ) {
                    addFiles(adapter.session)
                } else if route.adapterID == CodexFilePreviewWorkspaceTabAdapter.adapterID,
                          let adapter = CodexFilePreviewWorkspaceTabAdapter(
                              restoring: route,
                              within: workspaceURL
                          ),
                          previewKeys.insert(adapter.workspaceTabRegistration.resourceKey).inserted {
                    adapters.append(adapter)
                }
            } else if let adapter = CodexFilePreviewWorkspaceTabAdapter(
                restoring: instance.resourceKey,
                within: workspaceURL
            ),
            previewKeys.insert(adapter.workspaceTabRegistration.resourceKey).inserted {
                adapters.append(adapter)
            }
        }

        return .init(filesSession: filesSession, adapters: adapters)
    }
}
