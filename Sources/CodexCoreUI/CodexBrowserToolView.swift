import AppKit
import Foundation
import SwiftUI
@preconcurrency import WebKit

@MainActor
public final class CodexBrowserSession: ObservableObject, Identifiable {
    public let id: String
    public let fallbackTitle: String
    @Published public var addressText: String
    @Published public var pageTitle: String
    @Published public var currentURL: URL?
    @Published public var isLoading: Bool
    @Published public var canGoBack: Bool
    @Published public var canGoForward: Bool

    /// The live web view is owned by the session, not by the SwiftUI representable,
    /// so it survives the panel being hidden or the chat being switched away. Only
    /// `close()` (explicit tab close or store eviction) tears it down.
    public let webView: WKWebView
    private var surface: CodexBrowserSurface!
    private var isClosed = false

    public init(
        id: String = "browser:\(UUID().uuidString)",
        title: String = CodexWorkspaceToolCatalog.manualBrowserTitle
    ) {
        self.id = id
        self.fallbackTitle = title
        self.addressText = ""
        self.pageTitle = ""
        self.currentURL = nil
        self.isLoading = false
        self.canGoBack = false
        self.canGoForward = false

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.underPageBackgroundColor = .clear
        self.webView = webView
        self.surface = CodexBrowserSurface(session: self)
        surface.attach(to: webView)
    }

    public var title: String {
        let trimmedTitle = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? fallbackTitle : trimmedTitle
    }

    public func navigateToAddressText() {
        let url = CodexBrowserNavigationResolver.url(for: addressText)
        addressText = url.absoluteString
        currentURL = url
        guard !isClosed else { return }
        webView.load(URLRequest(url: url))
    }

    public func goBack() {
        guard !isClosed, webView.canGoBack else { return }
        webView.goBack()
    }

    public func goForward() {
        guard !isClosed, webView.canGoForward else { return }
        webView.goForward()
    }

    public func reloadOrStop() {
        guard !isClosed else { return }
        if isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        surface.detach(from: webView)
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        isLoading = false
        canGoBack = false
        canGoForward = false
    }
}

public enum CodexBrowserNavigationResolver {
    public static func url(for input: String) -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return searchURL(for: "")
        }

        if let explicitURL = explicitURL(from: trimmed) {
            return explicitURL
        }

        if let webURL = inferredWebURL(from: trimmed) {
            return webURL
        }

        return searchURL(for: trimmed)
    }

    private static func explicitURL(from input: String) -> URL? {
        guard let components = URLComponents(string: input),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              let url = components.url else {
            return nil
        }
        return url
    }

    private static func inferredWebURL(from input: String) -> URL? {
        guard input.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return nil
        }

        let scheme = usesLocalHTTP(input) ? "http" : "https"
        guard let components = URLComponents(string: "\(scheme)://\(input)"),
              let host = components.host,
              isLikelyHost(host),
              let url = components.url else {
            return nil
        }
        return url
    }

    private static func searchURL(for query: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "duckduckgo.com"
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url!
    }

    private static func usesLocalHTTP(_ input: String) -> Bool {
        let lowercased = input.lowercased()
        return lowercased == "localhost"
            || lowercased.hasPrefix("localhost:")
            || lowercased.hasPrefix("127.")
            || lowercased.hasPrefix("0.0.0.0")
            || lowercased.hasPrefix("[::1]")
    }

    private static func isLikelyHost(_ host: String) -> Bool {
        host == "localhost"
            || host.contains(".")
            || host.allSatisfy { $0.isNumber || $0 == "." }
    }
}

public struct CodexBrowserToolView: View {
    @Environment(\.codexAgentTheme) private var theme
    @ObservedObject private var session: CodexBrowserSession
    @FocusState private var isAddressFieldFocused: Bool

    public init(session: CodexBrowserSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.colors.border)
            CodexBrowserWebView(session: session)
                .background(theme.colors.surfaceSunken.opacity(0.8))
                .accessibilityLabel(CodexWorkspaceToolCatalog.manualBrowserAccessibilityLabel)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            browserButton(
                systemImage: "chevron.left",
                help: "Back",
                isEnabled: session.canGoBack,
                action: session.goBack
            )

            browserButton(
                systemImage: "chevron.right",
                help: "Forward",
                isEnabled: session.canGoForward,
                action: session.goForward
            )

            browserButton(
                systemImage: session.isLoading ? "xmark" : "arrow.clockwise",
                help: session.isLoading ? "Stop loading" : "Reload",
                isEnabled: session.currentURL != nil || session.isLoading,
                action: session.reloadOrStop
            )

            TextField("Search or enter URL", text: $session.addressText)
                .textFieldStyle(.plain)
                .font(theme.fonts.chat)
                .foregroundStyle(theme.colors.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(theme.colors.surfaceSunken.opacity(0.86), in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                        .stroke(isAddressFieldFocused ? theme.colors.accent.opacity(0.7) : theme.colors.border, lineWidth: 1)
                )
                .focused($isAddressFieldFocused)
                .onSubmit(session.navigateToAddressText)
                .accessibilityLabel(CodexWorkspaceToolCatalog.manualBrowserAddressAccessibilityLabel)

            browserButton(
                systemImage: "arrow.up.forward.square",
                help: "Open externally",
                isEnabled: session.currentURL != nil,
                action: openExternally
            )
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
    }

    private func browserButton(
        systemImage: String,
        help: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(theme.fonts.label)
                .foregroundStyle(isEnabled ? theme.colors.textSecondary : theme.colors.textTertiary.opacity(0.5))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private func openExternally() {
        guard let url = session.currentURL else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct CodexBrowserWebView: NSViewRepresentable {
    let session: CodexBrowserSession

    // Host the session-owned web view. It is intentionally not created or torn
    // down here so it survives the representable being dismantled (panel hidden,
    // chat switched). Lifetime is owned by CodexBrowserSession.
    func makeNSView(context: Context) -> WKWebView {
        session.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}

@MainActor
final class CodexBrowserSurface: NSObject, WKNavigationDelegate, WKUIDelegate {
    private weak var session: CodexBrowserSession?
    private var observations: [NSKeyValueObservation] = []

    init(session: CodexBrowserSession) {
        self.session = session
    }

    func attach(to webView: WKWebView) {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
                Task { @MainActor in self?.session?.canGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] webView, _ in
                Task { @MainActor in self?.session?.canGoForward = webView.canGoForward }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] webView, _ in
                Task { @MainActor in self?.session?.isLoading = webView.isLoading }
            },
            webView.observe(\.title, options: [.initial, .new]) { [weak self] webView, _ in
                Task { @MainActor in self?.session?.pageTitle = webView.title ?? "" }
            },
            webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
                Task { @MainActor in self?.updateURL(webView.url) }
            },
        ]
    }

    func detach(from webView: WKWebView) {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        updateURL(webView.url)
        session?.isLoading = webView.isLoading
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateURL(webView.url)
        session?.pageTitle = webView.title ?? ""
        session?.isLoading = webView.isLoading
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        updateURL(webView.url)
        session?.isLoading = webView.isLoading
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        updateURL(webView.url)
        session?.isLoading = webView.isLoading
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    private func updateURL(_ url: URL?) {
        session?.currentURL = url
        if let url {
            session?.addressText = url.absoluteString
        }
    }
}
