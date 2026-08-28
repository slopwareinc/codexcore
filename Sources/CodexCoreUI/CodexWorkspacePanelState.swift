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
    @Published public var filePreviewSessions: [CodexFilePreviewSession] = []
    @Published public var panelWidth: CGFloat
    @Published private(set) var openSubagentTabID: String?
    public let workspaceTabs: CodexWorkspaceTabs
    public let threadID: String?

    private var nextTerminalNumber = 1
    private var nextBrowserNumber = 1
    private var terminalTabIDs: [String: CodexWorkspaceTabID] = [:]

    public init(panelWidth: CGFloat = 400, threadID: String? = nil) {
        self.panelWidth = panelWidth
        self.workspaceTabs = CodexWorkspaceTabs()
        let trimmedThreadID = threadID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.threadID = trimmedThreadID?.isEmpty == true ? nil : trimmedThreadID
    }

    public var isAgentPanelOpen: Bool {
        get { workspaceTabs.snapshot.topology.right.isOpen }
        set { workspaceTabs.setOpen(newValue) }
    }

    public var hasOpenTools: Bool {
        !terminalSessions.isEmpty || !browserSessions.isEmpty || filesSession != nil
            || !filePreviewSessions.isEmpty
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
    public func openTerminal(
        workspacePath: String,
        threadID: String? = nil,
        command: String? = nil,
        placement: CodexWorkspaceTabPlacement = .bottom,
        focus: Bool = true
    ) -> String {
        let number = nextTerminalNumber
        nextTerminalNumber += 1
        let title = number == 1 ? "Terminal" : "Terminal \(number)"
        let identity = CodexTerminalIdentity(
            threadID: threadID ?? self.threadID,
            worktreePath: workspacePath,
            ordinal: number
        )
        let session = CodexTerminalSession(
            title: title,
            workingDirectory: workspacePath,
            command: command,
            identity: identity,
            isBackground: !focus
        )
        terminalSessions.append(session)
        let adapter = terminalAdapter(for: session, placement: placement)
        let tabID = workspaceTabs.open(
            adapter,
            from: focus ? .commandMenu : .background,
            placement: placement,
            focus: focus
        )
        terminalTabIDs[session.id] = tabID
        return session.id
    }

    @discardableResult
    public func openBackgroundTerminal(
        workspacePath: String,
        threadID: String? = nil,
        command: String? = nil,
        placement: CodexWorkspaceTabPlacement = .bottom
    ) -> String {
        openTerminal(
            workspacePath: workspacePath,
            threadID: threadID,
            command: command,
            placement: placement,
            focus: false
        )
    }

    public func terminalTabID(for terminalID: String) -> CodexWorkspaceTabID? {
        terminalTabIDs[terminalID]
    }

    /// The current terminal adapters are registered on every render pass so a
    /// restored route can become available without constructing a second PTY.
    public var terminalWorkspaceTabAdapters: [any CodexWorkspaceTabAdapter] {
        terminalSessions.map { session in
            let placement = terminalTabIDs[session.id]
                .flatMap { workspaceTabs.placement(of: $0) }
                ?? .bottom
            return terminalAdapter(for: session, placement: placement)
        }
    }

    public func closeTerminal(id: String) {
        let tabID = terminalTabIDs[id]
        if let tabID { workspaceTabs.close(tabID) }
        else { removeTerminalSession(id: id) }
    }

    private func removeTerminalSession(id: String) {
        terminalSessions.removeAll { $0.id == id }
        terminalTabIDs.removeValue(forKey: id)
    }

    private func terminalAdapter(
        for session: CodexTerminalSession,
        placement: CodexWorkspaceTabPlacement
    ) -> CodexTerminalWorkspaceTabAdapter {
        CodexTerminalWorkspaceTabAdapter(
            session: session,
            placement: placement,
            onClose: { [weak self] in
                self?.removeTerminalSession(id: session.id)
            }
        )
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
    public func openFiles(workspacePath: String) -> String {
        if let filesSession {
            workspaceTabs.activateLegacy(filesSession.id)
            return filesSession.id
        }
        let session = CodexFilesSession(rootURL: URL(fileURLWithPath: workspacePath))
        filesSession = session
        workspaceTabs.openLegacy(session.id)
        return session.id
    }

    public func closeFiles(id: String) {
        guard filesSession?.id == id else { return }
        filesSession = nil
        workspaceTabs.closeLegacy(id)
    }

    /// Opens a file (optionally at a ref) as its own preview tab, or reselects
    /// the existing tab for that file/ref combination.
    @discardableResult
    public func openFilePreview(fileURL: URL, ref: String? = nil) -> String {
        let id = CodexFilePreviewSession.identity(fileURL: fileURL, ref: ref)
        if let existing = filePreviewSessions.first(where: { $0.id == id }) {
            workspaceTabs.activateLegacy(existing.id)
            return existing.id
        }
        let session = CodexFilePreviewSession(fileURL: fileURL, ref: ref)
        filePreviewSessions.append(session)
        workspaceTabs.openLegacy(session.id)
        return session.id
    }

    public func closeFilePreview(id: String) {
        guard let index = filePreviewSessions.firstIndex(where: { $0.id == id }) else { return }
        filePreviewSessions.remove(at: index)
        workspaceTabs.closeLegacy(id)
    }

    /// Tear down every live session. Called when the store evicts this chat or
    /// the chat is closed/deleted.
    public func purge() {
        browserSessions.forEach { $0.close() }
        browserSessions.removeAll()
        terminalSessions.removeAll()
        filesSession = nil
        filePreviewSessions.removeAll()
        openSubagentTabID = nil
        terminalTabIDs.removeAll()
        workspaceTabs.removeAll()
    }
}
