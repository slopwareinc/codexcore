import AppKit
import CodexCore
import Combine
import Foundation
@preconcurrency import WebKit

public struct CodexVisualizationReference: Hashable, Sendable {
    public let fileURL: URL
    public let title: String
    public let isWide: Bool
    public let origin: CodexThreadResourceOrigin

    public init(fileURL: URL, title: String, isWide: Bool = false, origin: CodexThreadResourceOrigin) {
        self.fileURL = fileURL.standardizedFileURL
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "Visualization"
        self.isWide = isWide
        self.origin = origin
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
        guard resolved.lastPathComponent.range(
            of: #"^[a-z0-9]+(?:-[a-z0-9]+)*\.html$"#,
            options: .regularExpression
        ) != nil else { throw CodexVisualizationLoadError.invalidFileName }
        guard allowedRoots.contains(where: {
            resolved.path == $0.path || resolved.path.hasPrefix($0.path + "/")
        }) else { throw CodexVisualizationLoadError.outsideAllowedRoots }
        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { throw CodexVisualizationLoadError.missingFile }
        if let size = values.fileSize, size > Self.maximumBytes {
            throw CodexVisualizationLoadError.fileTooLarge(size)
        }
        return resolved
    }
}

enum CodexVisualizationFragmentLoader {
    @concurrent
    static func load(reference: CodexVisualizationReference, policy: CodexVisualizationPathPolicy) async throws -> String {
        try Task.checkCancellation()
        let url = try policy.validate(reference.fileURL)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw CodexVisualizationLoadError.unreadable
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: CodexVisualizationPathPolicy.maximumBytes + 1) else {
            throw CodexVisualizationLoadError.unreadable
        }
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
        "blob:", "data:", "https://cdnjs.cloudflare.com", "https://cdn.jsdelivr.net",
        "https://esm.sh", "https://fonts.bunny.net", "https://fonts.googleapis.com",
        "https://fonts.gstatic.com", "https://unpkg.com",
    ].joined(separator: " ")

    static func render(fragment: String, title: String) -> String {
        let framePolicy = [
            "default-src 'none'", "script-src 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval' \(resources)",
            "style-src 'unsafe-inline' \(resources)", "img-src \(resources)", "font-src \(resources)",
            "media-src \(resources)", "worker-src blob:", "connect-src blob: data:",
            "frame-src 'none'", "object-src 'none'", "base-uri 'none'", "form-action 'none'",
        ].joined(separator: "; ")
        let shellPolicy = framePolicy.replacingOccurrences(of: "frame-src 'none'", with: "frame-src 'self'")
        let safeTitle = escapeHTML(title)
        let frame = """
        <!doctype html><html lang="en"><head>
        <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="referrer" content="no-referrer">
        <meta http-equiv="Content-Security-Policy" content="\(framePolicy)">
        <title>\(safeTitle)</title>
        <style>html{color-scheme:light dark}body{margin:0;padding:16px;font:14px -apple-system,BlinkMacSystemFont,sans-serif;color:CanvasText;background:transparent}*{box-sizing:border-box}img,svg,canvas{max-width:100%}</style>
        </head><body>\(fragment)<script>
        (() => {
          window.openai = Object.freeze({
            sendFollowUpMessage: async ({prompt,title}={}) => {
              if(typeof prompt!=='string'||!prompt.trim()) throw new TypeError('prompt is required');
              parent.postMessage({type:'codex-follow-up',prompt,title}, '*');
            }
          });
          const report = () => parent.postMessage({type:'codex-visualization-height',height:Math.max(document.documentElement.scrollHeight,document.body.scrollHeight)}, '*');
          new ResizeObserver(report).observe(document.documentElement); addEventListener('load',report); report();
        })();
        </script></body></html>
        """
        return """
        <!doctype html><html lang="en"><head>
        <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="referrer" content="no-referrer">
        <meta http-equiv="Content-Security-Policy" content="\(shellPolicy)">
        <title>\(safeTitle)</title>
        <style>html,body{height:100%;margin:0;background:transparent}iframe{display:block;width:100%;height:100%;border:0}</style>
        </head><body><iframe sandbox="allow-scripts" referrerpolicy="no-referrer" title="\(safeTitle)" srcdoc="\(escapeAttribute(frame))"></iframe><script>
        addEventListener('message', event => { const frame=document.querySelector('iframe'); if(event.source!==frame.contentWindow)return; if(event.data?.type==='codex-visualization-height')window.webkit?.messageHandlers?.codexVisualizationHeight?.postMessage(event.data.height); if(event.data?.type==='codex-follow-up')window.webkit?.messageHandlers?.codexVisualizationHost?.postMessage(event.data); });
        </script></body></html>
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
    @Published public private(set) var state: CodexVisualizationLoadState = .unloaded {
        didSet { onLoadStateChanged?(state) }
    }
    @Published public private(set) var webView: WKWebView?
    public private(set) var loadCount = 0
    public private(set) var unloadCount = 0
    public var onWebViewChanged: ((WKWebView?) -> Void)?
    public var onPreferredHeightChanged: ((CGFloat) -> Void)?
    public var onFollowUpMessage: ((String, String?) -> Void)?
    public var onLoadStateChanged: ((CodexVisualizationLoadState) -> Void)?
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
                let fragment = try await CodexVisualizationFragmentLoader.load(reference: reference, policy: policy)
                try Task.checkCancellation()
                guard let self, self.isVisible else { self?.loadTask = nil; return }
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
                configuration.defaultWebpagePreferences.allowsContentJavaScript = true
                configuration.mediaTypesRequiringUserActionForPlayback = .all
                configuration.userContentController.add(CodexWeakVisualizationScriptHandler(owner: self), name: "codexVisualizationHeight")
                configuration.userContentController.add(CodexWeakVisualizationScriptHandler(owner: self), name: "codexVisualizationHost")
                let webView = WKWebView(frame: .zero, configuration: configuration)
                webView.navigationDelegate = self
                webView.uiDelegate = self
                webView.underPageBackgroundColor = .clear
                webView.loadHTMLString(CodexVisualizationSandboxDocument.render(fragment: fragment, title: reference.title), baseURL: nil)
                self.webView = webView
                self.onWebViewChanged?(webView)
                self.loadTask = nil
            } catch is CancellationError {
                self?.loadTask = nil
            } catch {
                self?.state = .failed(error.localizedDescription)
                self?.loadTask = nil
            }
        }
    }

    private func unload(keepVisibility: Bool = false) {
        loadTask?.cancel()
        loadTask = nil
        if let webView {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "codexVisualizationHeight")
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "codexVisualizationHost")
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.loadHTMLString("", baseURL: nil)
            unloadCount += 1
        }
        webView = nil
        onWebViewChanged?(nil)
        state = .unloaded
        if !keepVisibility { isVisible = false }
    }

    fileprivate func receivePreferredHeight(_ value: Double) {
        guard value.isFinite else { return }
        onPreferredHeightChanged?(min(10_000, max(44, ceil(value))))
    }

    fileprivate func receiveHostMessage(_ body: Any) {
        guard let payload = body as? [String: Any],
              payload["type"] as? String == "codex-follow-up",
              let prompt = (payload["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else { return }
        onFollowUpMessage?(prompt, payload["title"] as? String)
    }
}

private final class CodexWeakVisualizationScriptHandler: NSObject, WKScriptMessageHandler {
    weak var owner: CodexVisualizationSession?
    init(owner: CodexVisualizationSession) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor [weak owner] in
            if message.name == "codexVisualizationHeight", let number = message.body as? NSNumber {
                owner?.receivePreferredHeight(number.doubleValue)
            } else if message.name == "codexVisualizationHost" {
                owner?.receiveHostMessage(message.body)
            }
        }
    }
}

extension CodexVisualizationSession: WKNavigationDelegate, WKUIDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, isVisible else { return }
        state = .ready
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, isVisible else { return }
        state = .failed(error.localizedDescription)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, isVisible else { return }
        state = .failed(error.localizedDescription)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(url == nil || url?.scheme == "about" ? .allow : .cancel)
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
}
