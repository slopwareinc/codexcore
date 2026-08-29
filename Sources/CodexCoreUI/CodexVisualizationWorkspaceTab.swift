import AppKit
import CodexCore
import Foundation
import SwiftUI
@preconcurrency import WebKit

public struct CodexVisualizationReference: Codable, Hashable, Sendable, Equatable {
    public let fileURL: URL
    public let title: String
    public let isWide: Bool
    public let origin: CodexThreadResourceOrigin

    public init(
        fileURL: URL,
        title: String,
        isWide: Bool = false,
        origin: CodexThreadResourceOrigin
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            ?? "Visualization"
        self.isWide = isWide
        self.origin = origin
    }

    public var id: String {
        "\(origin.threadID.rawValue)|\(fileURL.standardizedFileURL.path)"
    }
}

public enum CodexVisualizationLoadError: Error, Sendable, Equatable, LocalizedError {
    case outsideAllowedRoots
    case invalidFileName
    case missingFile
    case fileTooLarge(Int)
    case unreadable
    case invalidUTF8

    public var errorDescription: String? {
        switch self {
        case .outsideAllowedRoots: "Visualization is outside the allowed output roots."
        case .invalidFileName: "Visualization file names must be lowercase, hyphenated HTML names."
        case .missingFile: "Visualization file is unavailable."
        case .fileTooLarge: "Visualization exceeds the 5 MB preview limit."
        case .unreadable: "Visualization could not be read."
        case .invalidUTF8: "Visualization is not valid UTF-8 HTML."
        }
    }
}

public struct CodexVisualizationPathPolicy: Sendable, Equatable {
    public static let maximumBytes = 5_000_000
    public let allowedRoots: [URL]

    public init(allowedRoots: [URL]) {
        var seen = Set<String>()
        self.allowedRoots = allowedRoots.compactMap { root in
            let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
            return seen.insert(resolved.path).inserted ? resolved : nil
        }
    }

    public func validate(_ fileURL: URL) throws -> URL {
        let resolved = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        let name = resolved.lastPathComponent
        guard name.range(
            of: #"^[a-z0-9]+(?:-[a-z0-9]+)*\.html$"#,
            options: .regularExpression
        ) != nil else { throw CodexVisualizationLoadError.invalidFileName }
        guard allowedRoots.contains(where: { root in
            resolved.path == root.path || resolved.path.hasPrefix(root.path + "/")
        }) else { throw CodexVisualizationLoadError.outsideAllowedRoots }
        guard let values = try? resolved.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        ), values.isRegularFile == true else {
            throw CodexVisualizationLoadError.missingFile
        }
        if let size = values.fileSize, size > Self.maximumBytes {
            throw CodexVisualizationLoadError.fileTooLarge(size)
        }
        return resolved
    }
}

enum CodexVisualizationFragmentLoader {
    @concurrent
    static func load(
        reference: CodexVisualizationReference,
        policy: CodexVisualizationPathPolicy
    ) async throws -> String {
        try Task.checkCancellation()
        let url = try policy.validate(reference.fileURL)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw CodexVisualizationLoadError.unreadable
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: CodexVisualizationPathPolicy.maximumBytes + 1) else {
            throw CodexVisualizationLoadError.unreadable
        }
        try Task.checkCancellation()
        guard data.count <= CodexVisualizationPathPolicy.maximumBytes else {
            throw CodexVisualizationLoadError.fileTooLarge(data.count)
        }
        guard let fragment = String(data: data, encoding: .utf8) else {
            throw CodexVisualizationLoadError.invalidUTF8
        }
        return fragment
    }
}

enum CodexVisualizationSandboxDocument {
    private static let resources = [
        "blob:", "data:",
        "https://cdnjs.cloudflare.com",
        "https://cdn.jsdelivr.net",
        "https://esm.sh",
        "https://fonts.bunny.net",
        "https://fonts.googleapis.com",
        "https://fonts.gstatic.com",
        "https://unpkg.com",
    ].joined(separator: " ")

    static func render(fragment: String, title: String) -> String {
        let framePolicy = [
            "default-src 'none'",
            "script-src 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval' \(resources)",
            "style-src 'unsafe-inline' \(resources)",
            "img-src \(resources)",
            "font-src \(resources)",
            "media-src \(resources)",
            "worker-src blob:",
            "connect-src blob: data:",
            "frame-src 'none'",
            "object-src 'none'",
            "base-uri 'none'",
            "form-action 'none'",
        ].joined(separator: "; ")
        let shellPolicy = framePolicy.replacingOccurrences(
            of: "frame-src 'none'",
            with: "frame-src 'self'"
        )
        let safeTitle = escapeHTML(title)
        let frame = """
        <!doctype html><html lang="en"><head>
        <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="referrer" content="no-referrer">
        <meta http-equiv="Content-Security-Policy" content="\(framePolicy)">
        <title>\(safeTitle)</title>
        <style>html{color-scheme:light dark}body{margin:0;padding:16px;font:14px -apple-system,BlinkMacSystemFont,sans-serif;color:CanvasText;background:transparent}*{box-sizing:border-box}img,svg,canvas{max-width:100%}</style>
        </head><body>\(fragment)</body></html>
        """
        return """
        <!doctype html><html lang="en"><head>
        <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="referrer" content="no-referrer">
        <meta http-equiv="Content-Security-Policy" content="\(shellPolicy)">
        <title>\(safeTitle)</title>
        <style>html,body{height:100%;margin:0;background:transparent}iframe{display:block;width:100%;height:100%;border:0}</style>
        </head><body><iframe sandbox="allow-scripts" referrerpolicy="no-referrer" title="\(safeTitle)" srcdoc="\(escapeAttribute(frame))"></iframe></body></html>
        """
    }

    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func escapeAttribute(_ value: String) -> String {
        escapeHTML(value).replacingOccurrences(of: "'", with: "&#39;")
    }
}

public enum CodexVisualizationLoadState: Sendable, Equatable {
    case unloaded
    case loading
    case ready
    case failed(String)
}

@MainActor
public final class CodexVisualizationSession: NSObject, ObservableObject {
    public let reference: CodexVisualizationReference
    public let policy: CodexVisualizationPathPolicy
    @Published public private(set) var state: CodexVisualizationLoadState = .unloaded
    @Published public private(set) var webView: WKWebView?
    public private(set) var loadCount = 0
    public private(set) var unloadCount = 0
    private var loadTask: Task<Void, Never>?
    private var isVisible = false

    public init(reference: CodexVisualizationReference, policy: CodexVisualizationPathPolicy) {
        self.reference = reference
        self.policy = policy
    }

    deinit { loadTask?.cancel() }

    public func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        visible ? load() : unload()
    }

    public func retry() {
        guard isVisible else { return }
        unload(keepVisibility: true)
        load()
    }

    public func close() {
        isVisible = false
        unload()
    }

    private func load() {
        guard loadTask == nil, webView == nil else { return }
        state = .loading
        loadCount += 1
        let reference = reference
        let policy = policy
        loadTask = Task { [weak self] in
            do {
                let fragment = try await CodexVisualizationFragmentLoader.load(
                    reference: reference,
                    policy: policy
                )
                try Task.checkCancellation()
                guard let self else { return }
                guard self.isVisible else {
                    self.loadTask = nil
                    return
                }
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
                configuration.defaultWebpagePreferences.allowsContentJavaScript = true
                configuration.mediaTypesRequiringUserActionForPlayback = .all
                let webView = WKWebView(frame: .zero, configuration: configuration)
                webView.navigationDelegate = self
                webView.uiDelegate = self
                webView.underPageBackgroundColor = .clear
                webView.loadHTMLString(
                    CodexVisualizationSandboxDocument.render(
                        fragment: fragment,
                        title: reference.title
                    ),
                    baseURL: nil
                )
                self.webView = webView
                self.loadTask = nil
            } catch is CancellationError {
                self?.loadTask = nil
            } catch {
                guard let self else { return }
                self.state = .failed(error.localizedDescription)
                self.loadTask = nil
            }
        }
    }

    private func unload(keepVisibility: Bool = false) {
        loadTask?.cancel()
        loadTask = nil
        if let webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.loadHTMLString("", baseURL: nil)
            unloadCount += 1
        }
        webView = nil
        state = .unloaded
        if !keepVisibility { isVisible = false }
    }
}

extension CodexVisualizationSession: WKNavigationDelegate, WKUIDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, isVisible else { return }
        state = .ready
    }

    public func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        guard webView === self.webView, isVisible else { return }
        state = .failed(error.localizedDescription)
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard webView === self.webView, isVisible else { return }
        state = .failed(error.localizedDescription)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        let allowed = url == nil || url?.scheme == "about"
        decisionHandler(allowed ? .allow : .cancel)
    }

    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? { nil }
}

@MainActor
public final class CodexVisualizationFrameStore: ObservableObject {
    public let maximumFrameCount: Int
    private var sessions: [String: CodexVisualizationSession] = [:]
    private var recency: [String] = []

    public init(maximumFrameCount: Int = 4) {
        self.maximumFrameCount = max(1, maximumFrameCount)
    }

    public var frameCount: Int { sessions.count }

    public func session(
        for reference: CodexVisualizationReference,
        policy: CodexVisualizationPathPolicy
    ) -> CodexVisualizationSession {
        let key = reference.id
        if let session = sessions[key] {
            touch(key)
            return session
        }
        let session = CodexVisualizationSession(reference: reference, policy: policy)
        sessions[key] = session
        touch(key)
        while sessions.count > maximumFrameCount, let victim = recency.first {
            recency.removeFirst()
            sessions.removeValue(forKey: victim)?.close()
        }
        return session
    }

    public func closeAll() {
        sessions.values.forEach { $0.close() }
        sessions.removeAll()
        recency.removeAll()
    }

    private func touch(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

public struct CodexVisualizationWorkspaceView: View {
    @Environment(\.codexAgentTheme) private var theme
    @ObservedObject private var session: CodexVisualizationSession
    @State private var isFullscreen = false

    public init(session: CodexVisualizationSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label(session.reference.title, systemImage: "chart.xyaxis.line")
                    .font(theme.fonts.label)
                    .lineLimit(1)
                Spacer()
                Button("Reload", systemImage: "arrow.clockwise", action: session.retry)
                    .labelStyle(.iconOnly)
                    .help("Reload visualization")
                Button("Full screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                    isFullscreen = true
                }
                .labelStyle(.iconOnly)
                .help("Open visualization full screen")
                Button("Export", systemImage: "square.and.arrow.down") { exportSource() }
                    .labelStyle(.iconOnly)
                    .help("Export visualization HTML")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .frame(height: 44)
            Divider().overlay(theme.colors.border)
            content
        }
        .onAppear { session.setVisible(true) }
        .onDisappear { if !isFullscreen { session.setVisible(false) } }
        .sheet(isPresented: $isFullscreen, onDismiss: { session.setVisible(true) }) {
            VStack(spacing: 0) {
                HStack {
                    Text(session.reference.title).font(theme.fonts.label)
                    Spacer()
                    Button("Close") { isFullscreen = false }
                }
                .padding(12)
                Divider()
                content
            }
            .frame(minWidth: 900, minHeight: 620)
            .onAppear { session.setVisible(true) }
        }
        .accessibilityLabel("Interactive visualization, \(session.reference.title)")
    }

    @ViewBuilder private var content: some View {
        switch session.state {
        case .unloaded, .loading:
            ProgressView("Loading visualization…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            CodexVisualizationWebView(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView(
                "Visualization unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .overlay(alignment: .bottom) {
                Button("Retry", action: session.retry).padding(24)
            }
        }
    }

    private func exportSource() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = session.reference.fileURL.lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard let data = try? Data(contentsOf: session.reference.fileURL) else { return }
        try? data.write(to: destination, options: .atomic)
    }
}

private struct CodexVisualizationWebView: NSViewRepresentable {
    @ObservedObject var session: CodexVisualizationSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
    }

    private func attach(to container: NSView) {
        container.subviews.filter { $0 !== session.webView }.forEach { $0.removeFromSuperview() }
        guard let webView = session.webView else { return }
        if webView.superview !== container {
            webView.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                webView.topAnchor.constraint(equalTo: container.topAnchor),
                webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
    }
}

@MainActor
package struct CodexVisualizationWorkspaceTabAdapter: CodexWorkspaceTabAdapter {
    package static let adapterID = "codex.visualization"
    package static let routeVersion = 1
    package let reference: CodexVisualizationReference
    package let session: CodexVisualizationSession

    package init?(
        resource: CodexThreadResource,
        workspaceURL: URL,
        visualizationRoots: [URL],
        frameStore: CodexVisualizationFrameStore
    ) {
        guard resource.kind == .visualization,
              let path = resource.metadata.path else { return nil }
        let fileURL = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : workspaceURL.appendingPathComponent(path)
        let policy = CodexVisualizationPathPolicy(
            allowedRoots: [workspaceURL] + visualizationRoots
        )
        guard let validated = try? policy.validate(fileURL) else { return nil }
        let reference = CodexVisualizationReference(
            fileURL: validated,
            title: resource.title,
            isWide: resource.metadata.statusDetail == "wide",
            origin: resource.origin
        )
        self.reference = reference
        self.session = frameStore.session(for: reference, policy: policy)
    }

    package init?(
        route: CodexWorkspaceTabRoute,
        workspaceURL: URL,
        visualizationRoots: [URL],
        frameStore: CodexVisualizationFrameStore
    ) {
        guard route.adapterID == Self.adapterID,
              route.version == Self.routeVersion,
              let reference = try? JSONDecoder().decode(
                CodexVisualizationReference.self,
                from: route.payload
              ) else { return nil }
        let policy = CodexVisualizationPathPolicy(
            allowedRoots: [workspaceURL] + visualizationRoots
        )
        guard (try? policy.validate(reference.fileURL)) != nil else { return nil }
        self.reference = reference
        self.session = frameStore.session(for: reference, policy: policy)
    }

    package var workspaceTabRegistration: CodexWorkspaceTabRegistration {
        CodexWorkspaceTabRegistration(
            resourceKey: "\(Self.adapterID):\(reference.id)",
            title: reference.title,
            systemImage: "chart.xyaxis.line",
            retentionPolicy: .retained,
            durableRoute: .init(
                adapterID: Self.adapterID,
                version: Self.routeVersion,
                resourceID: reference.id,
                payload: (try? JSONEncoder().encode(reference)) ?? Data()
            ),
            onClose: session.close,
            preferredPlacement: .right,
            onVisibilityChanged: session.setVisible
        ) { _ in
            AnyView(CodexVisualizationWorkspaceView(session: session))
        }
    }
}

@MainActor
package enum CodexVisualizationWorkspaceTabAdapterRegistry {
    package static func make(
        snapshot: CodexWorkspaceTabSnapshot,
        workspaceURL: URL,
        visualizationRoots: [URL],
        frameStore: CodexVisualizationFrameStore
    ) -> [CodexVisualizationWorkspaceTabAdapter] {
        snapshot.instances.compactMap(\.durableRoute)
            .filter { $0.adapterID == CodexVisualizationWorkspaceTabAdapter.adapterID }
            .compactMap {
                CodexVisualizationWorkspaceTabAdapter(
                    route: $0,
                    workspaceURL: workspaceURL,
                    visualizationRoots: visualizationRoots,
                    frameStore: frameStore
                )
            }
    }
}
