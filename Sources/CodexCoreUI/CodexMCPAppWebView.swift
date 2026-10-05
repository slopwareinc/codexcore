import AppKit
import SwiftUI
import WebKit
import CodexCore

/// A nonpersistent webview containing a separate opaque-origin app iframe.
/// This wrapper is the only frame allowed to call the native script handler.
struct CodexMCPAppWebView: NSViewRepresentable {
    let resource: CodexMCPAppResource
    let bridge: CodexMCPAppBridge
    let theme: String
    var styleVariables: [String: String] = [:]

    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge, theme: theme, styleVariables: styleVariables) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "codexMCPApp")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.webView = view
        view.loadHTMLString(resource.wrapperHTML(), baseURL: nil)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.theme != theme || context.coordinator.styleVariables != styleVariables {
            context.coordinator.theme = theme
            context.coordinator.styleVariables = styleVariables
            if bridge.canNotifyHostContext {
                context.coordinator.deliver(CodexMCPAppBridge.notification("ui/notifications/host-context-changed", .dictionary([
                    "theme": .string(theme), "styles": .dictionary(["variables": .dictionary(styleVariables.mapValues(CodexJSONValue.string))]),
                ])))
            }
        }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.deliver(.dictionary(["jsonrpc": .string("2.0"), "id": .string("codex-host-teardown"),
                                         "method": .string("ui/resource-teardown"),
                                         "params": .dictionary(["reason": .string("View closed")])]))
        coordinator.stop()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "codexMCPApp")
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let bridge: CodexMCPAppBridge
        var theme: String
        var styleVariables: [String: String]
        weak var webView: WKWebView?
        private var tasks: [String: Task<Void, Never>] = [:]
        private var isStopped = false

        init(bridge: CodexMCPAppBridge, theme: String, styleVariables: [String: String] = [:]) {
            self.bridge = bridge; self.theme = theme; self.styleVariables = styleVariables
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !isStopped, message.frameInfo.isMainFrame,
                  JSONSerialization.isValidJSONObject(message.body),
                  let data = try? JSONSerialization.data(withJSONObject: message.body), data.count <= 262_144,
                  let value = try? JSONDecoder().decode(CodexJSONValue.self, from: data),
                  let fields = value.objectValue, fields["jsonrpc"] == .string("2.0"),
                  tasks.count < 8 else { return }
            let key: String
            if let id = fields["id"] {
                guard CodexMCPAppBridge.validRequestID(id),
                      let bytes = try? JSONEncoder().encode(id) else { return }
                key = String(decoding: bytes, as: UTF8.self)
            } else { key = UUID().uuidString }
            guard tasks[key] == nil else { return }
            tasks[key] = Task { [weak self] in
                guard let self else { return }
                defer { self.tasks.removeValue(forKey: key) }
                let replies = await self.bridge.handle(value, theme: self.theme, styleVariables: self.styleVariables)
                guard !Task.isCancelled, !self.isStopped else { return }
                for reply in replies { self.deliver(reply) }
            }
        }

        func deliver(_ value: CodexJSONValue) {
            guard let view = webView, !isStopped, let data = try? JSONEncoder().encode(value),
                  let object = try? JSONSerialization.jsonObject(with: data) else { return }
            view.callAsyncJavaScript("window.codexDeliver(message)", arguments: ["message": object], in: nil, in: .page) { _ in }
        }

        func stop() {
            isStopped = true
            for task in tasks.values { task.cancel() }
            tasks.removeAll()
            bridge.stop()
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            // The main document is generated locally. App-initiated document navigation
            // and downloads are disabled; external links use the confirmed RPC boundary.
            let url = navigationAction.request.url
            let internalDocument = url?.scheme == "about" && (url?.absoluteString == "about:blank" || url?.absoluteString == "about:srcdoc")
            decisionHandler(internalDocument ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    }
}
