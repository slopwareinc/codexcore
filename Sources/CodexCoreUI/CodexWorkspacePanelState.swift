import SwiftUI

/// Durable per-chat state for the workspace tool panel (the right-hand "sidebar").
///
/// This owns the tool *sessions* — terminals (ghostty), browsers (WebKit), and
/// the files explorer — along with the panel's open/selection/width state. It is
/// deliberately a reference type held outside any transient SwiftUI view so that
/// hiding the panel or switching chats only recycles the view *surface*; the
/// underlying PTYs and web views stay alive until the session is explicitly
/// closed or the owning store evicts this chat.
@MainActor
public final class CodexWorkspacePanelState: ObservableObject {
    @Published public var terminalSessions: [CodexTerminalSession] = []
    @Published public var browserSessions: [CodexBrowserSession] = []
    @Published public var filesSession: CodexFilesSession?
    @Published public var panelWidth: CGFloat
    @Published private(set) var openSubagentTabID: String?
    public let workspaceTabs: CodexWorkspaceTabs

    private var nextTerminalNumber = 1
    private var nextBrowserNumber = 1

    public init(
        panelWidth: CGFloat = 400,
        restorationState: CodexWorkspaceTabRestorationState? = nil
    ) {
        self.panelWidth = panelWidth
        self.workspaceTabs = restorationState.map(CodexWorkspaceTabs.init(restoring:))
            ?? CodexWorkspaceTabs()
    }

    public var workspaceTabRestorationState: CodexWorkspaceTabRestorationState {
        workspaceTabs.restorationState
    }

    public func applyWorkspaceTabRestoration(
        _ restorationState: CodexWorkspaceTabRestorationState
    ) {
        workspaceTabs.apply(restoration: restorationState)
    }

    public var isAgentPanelOpen: Bool {
        get { workspaceTabs.snapshot.topology.right.isOpen }
        set { workspaceTabs.setOpen(newValue) }
    }

    public var hasOpenTools: Bool {
        !terminalSessions.isEmpty || !browserSessions.isEmpty || filesSession != nil
            || workspaceTabs.hasOpenWorkspaceTabs
    }

    func agentTabs(
        sideChat: CodexSideChatState? = nil,
        subagents: [CodexSubagentState]
    ) -> [CodexAgentPanelTab] {
        var tabs: [CodexAgentPanelTab] = []
        if let sideChat { tabs.append(.sideChat(sideChat)) }
        if let openSubagentTabID,
           let subagent = subagents.first(where: { $0.id == openSubagentTabID })
        {
            tabs.append(.subagent(subagent))
        }
        return tabs
    }

    func openSubagent(id: String) {
        openSubagentTabID = id
        workspaceTabs.openLegacy(id)
    }

    func closeSubagent(id: String) {
        guard openSubagentTabID == id else { return }
        openSubagentTabID = nil
        workspaceTabs.closeLegacy(id)
    }

    // MARK: - Tool lifecycle

    @discardableResult
    public func openTerminal(workspacePath: String) -> String {
        let number = nextTerminalNumber
        nextTerminalNumber += 1
        let title = number == 1 ? "Terminal" : "Terminal \(number)"
        let session = CodexTerminalSession(title: title, workingDirectory: workspacePath)
        terminalSessions.append(session)
        workspaceTabs.openLegacy(session.id)
        return session.id
    }

    public func closeTerminal(id: String) {
        terminalSessions.removeAll { $0.id == id }
        workspaceTabs.closeLegacy(id)
    }

    @discardableResult
    public func openBrowser() -> String {
        let number = nextBrowserNumber
        nextBrowserNumber += 1
        let title = number == 1 ? "Browser" : "Browser \(number)"
        let session = CodexBrowserSession(title: title)
        browserSessions.append(session)
        workspaceTabs.openLegacy(session.id)
        return session.id
    }

    public func closeBrowser(id: String) {
        browserSessions.first { $0.id == id }?.close()
        browserSessions.removeAll { $0.id == id }
        workspaceTabs.closeLegacy(id)
    }

    /// Opens the workspace files explorer, or reselects the existing one.
    @discardableResult
    public func openFiles(workspacePath: String) -> CodexWorkspaceTabID {
        if let filesSession {
            return workspaceTabs.open(filesAdapter(for: filesSession), from: .commandMenu)
        }
        let session = CodexFilesSession(rootURL: URL(fileURLWithPath: workspacePath))
        filesSession = session
        return workspaceTabs.open(filesAdapter(for: session), from: .commandMenu)
    }

    /// Opens a file (optionally at a ref) as its own preview tab, or reselects
    /// the existing tab for that file/ref combination.
    @discardableResult
    public func openFilePreview(fileURL: URL, ref: String? = nil) -> CodexWorkspaceTabID {
        workspaceTabs.open(
            CodexFilePreviewWorkspaceTabAdapter(fileURL: fileURL, ref: ref),
            from: .transcript
        )
    }

    /// Tear down every live session. Called when the store evicts this chat or
    /// the chat is closed/deleted.
    public func purge() {
        browserSessions.forEach { $0.close() }
        browserSessions.removeAll()
        terminalSessions.removeAll()
        filesSession = nil
        openSubagentTabID = nil
        workspaceTabs.removeAll()
    }

    private func filesAdapter(for session: CodexFilesSession) -> CodexFilesWorkspaceTabAdapter {
        CodexFilesWorkspaceTabAdapter(
            session: session,
            onOpenFile: { [weak self] url in
                _ = self?.openFilePreview(fileURL: url)
            },
            onClose: { [weak self] in
                guard self?.filesSession?.id == session.id else { return }
                self?.filesSession = nil
            }
        )
    }
}
