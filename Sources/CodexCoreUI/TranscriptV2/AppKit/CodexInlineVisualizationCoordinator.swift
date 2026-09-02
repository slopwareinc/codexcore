import AppKit
import CodexCore
import Combine
import Foundation
@preconcurrency import WebKit

@MainActor
final class CodexInlineVisualizationAnchorView: NSView {
    let messageLabel = NSTextField(labelWithString: "Loading visualization…")
    let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    let expandButton = NSButton(title: "", target: nil, action: nil)
    var onRetry: (() -> Void)?
    var onExpand: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        addSubview(messageLabel)
        retryButton.target = self
        retryButton.action = #selector(retry)
        retryButton.isHidden = true
        addSubview(retryButton)
        expandButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Expand visualization")
        expandButton.bezelStyle = .accessoryBarAction
        expandButton.target = self
        expandButton.action = #selector(expand)
        addSubview(expandButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        messageLabel.frame = bounds.insetBy(dx: 16, dy: 16)
        retryButton.sizeToFit()
        retryButton.frame.origin = CGPoint(
            x: bounds.midX - retryButton.frame.width / 2,
            y: max(12, bounds.midY - retryButton.frame.height - 12)
        )
        expandButton.frame = NSRect(x: bounds.maxX - 36, y: bounds.maxY - 36, width: 28, height: 28)
        subviews.compactMap { $0 as? WKWebView }.forEach { $0.frame = bounds }
    }

    @objc private func retry() { onRetry?() }
    @objc private func expand() { onExpand?() }
}

/// Retains inline visualization frames independently from virtualized transcript
/// cells. A recycled cell only detaches its anchor; the web document remains
/// available for reattachment while its source thread is active.
@MainActor
public final class CodexInlineVisualizationCoordinator: ObservableObject {
    private struct Attachment {
        weak var anchor: CodexInlineVisualizationAnchorView?
        var onHeightChange: (CGFloat) -> Void
    }

    private final class Record {
        let session: CodexVisualizationSession
        var attachment: Attachment?
        var detachTask: Task<Void, Never>?

        init(session: CodexVisualizationSession) {
            self.session = session
        }
    }

    private let policy: CodexVisualizationPathPolicy
    private let onFollowUpMessage: (String) -> Void
    private var records: [String: Record] = [:]
    private var fullscreenControllers: [String: CodexVisualizationFullscreenController] = [:]
    private var activeThreadID: String?
    private var isApplicationActive = true
    private var cancellables: Set<AnyCancellable> = []

    var frameCountForTesting: Int { records.count }
    var sessionsForTesting: [CodexVisualizationSession] { records.values.map(\.session) }

    public init(allowedRoots: [URL], onFollowUpMessage: @escaping (String) -> Void = { _ in }) {
        policy = CodexVisualizationPathPolicy(allowedRoots: allowedRoots)
        self.onFollowUpMessage = onFollowUpMessage
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isApplicationActive = false
                    self.records.values.forEach { $0.session.setVisible(false) }
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isApplicationActive = true
                    for (key, record) in self.records where key.hasPrefix((self.activeThreadID ?? "") + "|") {
                        record.session.setVisible(record.attachment?.anchor != nil)
                    }
                }
            }
            .store(in: &cancellables)
    }

    func setActiveThread(_ threadID: String) {
        guard activeThreadID != threadID else { return }
        activeThreadID = threadID
        for (key, record) in records {
            let isActive = key.hasPrefix(threadID + "|")
            record.session.setVisible(isApplicationActive && isActive && record.attachment?.anchor != nil)
        }
    }

    func attach(
        _ visualization: CodexTranscriptVisualizationRender,
        itemID: CodexTranscriptRenderItemID,
        threadID: String,
        to anchor: CodexInlineVisualizationAnchorView,
        onHeightChange: @escaping (CGFloat) -> Void
    ) {
        setActiveThread(threadID)
        let sourceThreadID = visualization.sourceThreadID ?? threadID
        let key = "\(threadID)|\(itemID.rawValue)|\(visualization.path)"
        let record: Record
        if let existing = records[key] {
            record = existing
        } else {
            let reference = CodexVisualizationReference(
                fileURL: resolvedFileURL(for: visualization.path),
                title: visualization.title,
                isWide: visualization.isWide,
                origin: .init(threadID: ThreadID(sourceThreadID), turnID: TurnID(itemID.rawValue))
            )
            record = Record(session: CodexVisualizationSession(reference: reference, policy: policy))
            records[key] = record
        }

        detach(anchor)
        record.detachTask?.cancel()
        record.detachTask = nil
        record.attachment = Attachment(anchor: anchor, onHeightChange: onHeightChange)
        anchor.messageLabel.stringValue = "Loading \(visualization.title)…"
        anchor.messageLabel.isHidden = false
        anchor.retryButton.isHidden = true
        anchor.expandButton.isHidden = !visualization.isExpandable
        anchor.onRetry = { [weak record] in record?.session.retry() }
        anchor.onExpand = { [weak self] in self?.presentFullscreen(key: key, title: visualization.title) }
        record.session.onWebViewChanged = { [weak self, weak anchor] webView in
            guard let self, let anchor,
                  self.records[key]?.attachment?.anchor === anchor else { return }
            anchor.subviews.compactMap { $0 as? WKWebView }.forEach { $0.removeFromSuperview() }
            guard let webView else {
                anchor.messageLabel.isHidden = false
                return
            }
            webView.frame = anchor.bounds
            webView.autoresizingMask = [.width, .height]
            anchor.addSubview(webView, positioned: .above, relativeTo: anchor.messageLabel)
            anchor.messageLabel.isHidden = true
            anchor.retryButton.isHidden = true
        }
        record.session.onPreferredHeightChanged = { [weak self, weak anchor] height in
            guard let self, let anchor,
                  let attachment = self.records[key]?.attachment,
                  attachment.anchor === anchor else { return }
            attachment.onHeightChange(height)
        }
        record.session.onFollowUpMessage = { [weak self] prompt, title in
            self?.confirmFollowUp(prompt: prompt, title: title)
        }
        record.session.onLoadStateChanged = { [weak anchor] state in
            guard let anchor else { return }
            if case .failed(let message) = state {
                anchor.messageLabel.stringValue = "Visualization unavailable\n\(message)"
                anchor.messageLabel.isHidden = false
                anchor.retryButton.isHidden = false
            }
        }
        if let webView = record.session.webView {
            webView.removeFromSuperview()
            webView.frame = anchor.bounds
            webView.autoresizingMask = [.width, .height]
            anchor.addSubview(webView, positioned: .above, relativeTo: anchor.messageLabel)
            anchor.messageLabel.isHidden = true
            anchor.retryButton.isHidden = true
        }
        record.session.setVisible(isApplicationActive && activeThreadID == threadID)
    }

    func detach(_ anchor: CodexInlineVisualizationAnchorView) {
        for record in records.values where record.attachment?.anchor === anchor {
            record.attachment = nil
            record.session.webView?.removeFromSuperview()
            record.detachTask?.cancel()
            record.detachTask = Task { [weak record] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let record, record.attachment == nil else { return }
                record.session.setVisible(false)
            }
        }
    }

    func retainOnly(itemIDs: Set<CodexTranscriptRenderItemID>, threadID: String) {
        let liveIDs = Set(itemIDs.map(\.rawValue))
        let staleKeys = records.keys.filter { key in
            guard key.hasPrefix(threadID + "|") else { return false }
            let fields = key.split(separator: "|", maxSplits: 2).map(String.init)
            return fields.count < 2 || !liveIDs.contains(fields[1])
        }
        for key in staleKeys {
            let record = records.removeValue(forKey: key)
            record?.detachTask?.cancel()
            record?.session.close()
        }
    }

    public func closeAll() {
        records.values.forEach { $0.session.close() }
        records.values.forEach { $0.detachTask?.cancel() }
        records.removeAll()
        Array(fullscreenControllers.values).forEach { $0.close() }
        fullscreenControllers.removeAll()
    }

    private func confirmFollowUp(prompt: String, title: String?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title?.nilIfBlank ?? "Send follow-up?"
        alert.informativeText = prompt
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onFollowUpMessage(prompt)
    }

    private func resolvedFileURL(for path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        let candidates = policy.allowedRoots.map { $0.appendingPathComponent(path) }
        return candidates.first(where: { (try? policy.validate($0)) != nil })
            ?? candidates.first
            ?? URL(fileURLWithPath: path)
    }

    private func presentFullscreen(key: String, title: String) {
        guard fullscreenControllers[key] == nil,
              let record = records[key], let webView = record.session.webView else { return }
        webView.removeFromSuperview()
        let controller = CodexVisualizationFullscreenController(title: title, webView: webView) { [weak self] in
            guard let self else { return }
            self.fullscreenControllers.removeValue(forKey: key)
            guard let record = self.records[key], let anchor = record.attachment?.anchor,
                  let webView = record.session.webView else { return }
            webView.removeFromSuperview()
            webView.frame = anchor.bounds
            anchor.addSubview(webView, positioned: .above, relativeTo: anchor.messageLabel)
        }
        fullscreenControllers[key] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class CodexVisualizationFullscreenController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(title: String, webView: WKWebView, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.contentView = webView
        panel.center()
        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) { onClose() }
}
