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
    @Published fileprivate var navigationCommand: CodexBrowserNavigationCommand?
    @Published fileprivate var closeToken: UUID?

    public init(
        id: String = "browser:\(UUID().uuidString)",
        title: String = "Browser"
    ) {
        self.id = id
        self.fallbackTitle = title
        self.addressText = ""
        self.pageTitle = ""
        self.currentURL = nil
        self.isLoading = false
        self.canGoBack = false
        self.canGoForward = false
    }

    public var title: String {
        let trimmedTitle = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? fallbackTitle : trimmedTitle
    }

    public func navigateToAddressText() {
        let url = CodexBrowserNavigationResolver.url(for: addressText)
        addressText = url.absoluteString
        currentURL = url
        navigationCommand = CodexBrowserNavigationCommand(action: .load(url))
    }

    public func goBack() {
        navigationCommand = CodexBrowserNavigationCommand(action: .goBack)
    }

    public func goForward() {
        navigationCommand = CodexBrowserNavigationCommand(action: .goForward)
    }

    public func reloadOrStop() {
        navigationCommand = CodexBrowserNavigationCommand(action: isLoading ? .stopLoading : .reload)
    }

    public func close() {
        navigationCommand = CodexBrowserNavigationCommand(action: .close)
        closeToken = UUID()
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

private struct CodexBrowserNavigationCommand: Equatable {
    var id = UUID()
    var action: Action

    enum Action: Equatable {
        case load(URL)
        case goBack
        case goForward
        case reload
        case stopLoading
        case close
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
                .accessibilityLabel("Browser")
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
                .accessibilityLabel("Browser address")

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
    @ObservedObject var session: CodexBrowserSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.underPageBackgroundColor = .clear
        context.coordinator.attach(to: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.performPendingCommand(on: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.close(webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let session: CodexBrowserSession
        private var observations: [NSKeyValueObservation] = []
        private var handledCommandID: UUID?
        private var handledCloseToken: UUID?

        init(session: CodexBrowserSession) {
            self.session = session
        }

        func attach(to webView: WKWebView) {
            webView.navigationDelegate = self
            webView.uiDelegate = self
            observations = [
                webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
                    Task { @MainActor in self?.session.canGoBack = webView.canGoBack }
                },
                webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] webView, _ in
                    Task { @MainActor in self?.session.canGoForward = webView.canGoForward }
                },
                webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] webView, _ in
                    Task { @MainActor in self?.session.isLoading = webView.isLoading }
                },
                webView.observe(\.title, options: [.initial, .new]) { [weak self] webView, _ in
                    Task { @MainActor in self?.session.pageTitle = webView.title ?? "" }
                },
                webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
                    Task { @MainActor in self?.updateURL(webView.url) }
                },
            ]
        }

        func performPendingCommand(on webView: WKWebView) {
            guard let command = session.navigationCommand,
                  command.id != handledCommandID else {
                return
            }

            handledCommandID = command.id
            switch command.action {
            case .load(let url):
                webView.load(URLRequest(url: url))
            case .goBack:
                if webView.canGoBack { webView.goBack() }
            case .goForward:
                if webView.canGoForward { webView.goForward() }
            case .reload:
                webView.reload()
            case .stopLoading:
                webView.stopLoading()
            case .close:
                close(webView)
            }

            if let closeToken = session.closeToken,
               closeToken != handledCloseToken {
                handledCloseToken = closeToken
                close(webView)
            }
        }

        func close(_ webView: WKWebView) {
            observations.forEach { $0.invalidate() }
            observations.removeAll()
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.loadHTMLString("", baseURL: nil)
            session.isLoading = false
            session.canGoBack = false
            session.canGoForward = false
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            updateURL(webView.url)
            session.isLoading = webView.isLoading
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            updateURL(webView.url)
            session.pageTitle = webView.title ?? ""
            session.isLoading = webView.isLoading
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            updateURL(webView.url)
            session.isLoading = webView.isLoading
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            updateURL(webView.url)
            session.isLoading = webView.isLoading
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
            session.currentURL = url
            if let url {
                session.addressText = url.absoluteString
            }
        }
    }
}
