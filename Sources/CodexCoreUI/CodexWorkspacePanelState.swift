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
    @Published public var isAgentPanelOpen: Bool = false
    @Published public var selectedTabID: String?
    @Published public var panelWidth: CGFloat
    @Published private(set) var openSubagentTabID: String?

    private var nextTerminalNumber = 1
    private var nextBrowserNumber = 1

    public init(panelWidth: CGFloat = 400) {
        self.panelWidth = panelWidth
    }

    public var hasOpenTools: Bool {
        !terminalSessions.isEmpty || !browserSessions.isEmpty || filesSession != nil
            || !filePreviewSessions.isEmpty
    }

    func agentTabs(
        sideChat: CodexSideChatState? = nil,
        subagents: [CodexSubagentState],
        gitReviewSession: CodexGitReviewSession? = nil
    ) -> [CodexAgentPanelTab] {
        var tabs: [CodexAgentPanelTab] = []
        if let gitReviewSession { tabs.append(.review(gitReviewSession)) }
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
        selectedTabID = id
    }

    func closeSubagent(id: String, fallbackTabIDs: [String]) {
        guard openSubagentTabID == id else { return }
        openSubagentTabID = nil
        if selectedTabID == id {
            selectedTabID = firstAvailableTabID(fallbackTabIDs.filter { $0 != id })
        }
    }

    // MARK: - Tool lifecycle

    @discardableResult
    public func openTerminal(workspacePath: String) -> String {
        let number = nextTerminalNumber
        nextTerminalNumber += 1
        let title = number == 1 ? "Terminal" : "Terminal \(number)"
        let session = CodexTerminalSession(title: title, workingDirectory: workspacePath)
        terminalSessions.append(session)
        selectedTabID = session.id
        return session.id
    }

    public func closeTerminal(id: String, fallbackTabIDs: [String]) {
        terminalSessions.removeAll { $0.id == id }
        if selectedTabID == id {
            selectedTabID = firstAvailableTabID(fallbackTabIDs)
        }
    }

    @discardableResult
    public func openBrowser() -> String {
        let number = nextBrowserNumber
        nextBrowserNumber += 1
        let title = number == 1 ? "Browser" : "Browser \(number)"
        let session = CodexBrowserSession(title: title)
        browserSessions.append(session)
        selectedTabID = session.id
        return session.id
    }

    public func closeBrowser(id: String, fallbackTabIDs: [String]) {
        browserSessions.first { $0.id == id }?.close()
        browserSessions.removeAll { $0.id == id }
        if selectedTabID == id {
            selectedTabID = firstAvailableTabID(fallbackTabIDs)
        }
    }

    /// Opens the workspace files explorer, or reselects the existing one.
    @discardableResult
    public func openFiles(workspacePath: String) -> String {
        if let filesSession {
            selectedTabID = filesSession.id
            return filesSession.id
        }
        let session = CodexFilesSession(rootURL: URL(fileURLWithPath: workspacePath))
        filesSession = session
        selectedTabID = session.id
        return session.id
    }

    public func closeFiles(id: String, fallbackTabIDs: [String]) {
        guard filesSession?.id == id else { return }
        filesSession = nil
        if selectedTabID == id {
            selectedTabID = firstAvailableTabID(fallbackTabIDs)
        }
    }

    /// Opens a file (optionally at a ref) as its own preview tab, or reselects
    /// the existing tab for that file/ref combination.
    @discardableResult
    public func openFilePreview(fileURL: URL, ref: String? = nil) -> String {
        let id = CodexFilePreviewSession.identity(fileURL: fileURL, ref: ref)
        if let existing = filePreviewSessions.first(where: { $0.id == id }) {
            selectedTabID = existing.id
            return existing.id
        }
        let session = CodexFilePreviewSession(fileURL: fileURL, ref: ref)
        filePreviewSessions.append(session)
        selectedTabID = session.id
        return session.id
    }

    public func closeFilePreview(id: String, fallbackTabIDs: [String]) {
        guard let index = filePreviewSessions.firstIndex(where: { $0.id == id }) else { return }
        filePreviewSessions.remove(at: index)
        if selectedTabID == id {
            selectedTabID = firstAvailableTabID(fallbackTabIDs)
        }
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
        selectedTabID = nil
        isAgentPanelOpen = false
    }

    private func firstAvailableTabID(_ fallbackTabIDs: [String]) -> String? {
        terminalSessions.first?.id
            ?? browserSessions.first?.id
            ?? filesSession?.id
            ?? filePreviewSessions.first?.id
            ?? fallbackTabIDs.first
    }
}
