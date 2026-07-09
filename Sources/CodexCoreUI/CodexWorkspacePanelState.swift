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
    @Published public var isAgentPanelOpen: Bool = false
    @Published public var selectedTabID: String?
    @Published public var panelWidth: CGFloat

    private var nextTerminalNumber = 1
    private var nextBrowserNumber = 1

    public init(panelWidth: CGFloat = 320) {
        self.panelWidth = panelWidth
    }

    public var hasOpenTools: Bool {
        !terminalSessions.isEmpty || !browserSessions.isEmpty || filesSession != nil
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

    /// Tear down every live session. Called when the store evicts this chat or
    /// the chat is closed/deleted.
    public func purge() {
        browserSessions.forEach { $0.close() }
        browserSessions.removeAll()
        terminalSessions.removeAll()
        filesSession = nil
        selectedTabID = nil
        isAgentPanelOpen = false
    }

    private func firstAvailableTabID(_ fallbackTabIDs: [String]) -> String? {
        terminalSessions.first?.id
            ?? browserSessions.first?.id
            ?? filesSession?.id
            ?? fallbackTabIDs.first
    }
}
