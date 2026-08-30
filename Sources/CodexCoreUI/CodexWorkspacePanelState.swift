import SwiftUI

/// Durable per-chat state for the workspace tool panels (right and bottom).
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
    public let workspaceTabs: CodexWorkspaceTabs
    public let threadID: String?

    private var nextTerminalNumber = 1
    private var nextBrowserNumber = 1
    private var terminalTabIDs: [String: CodexWorkspaceTabID] = [:]
    private var restoredTerminalPayloads: [CodexWorkspaceTabID: CodexTerminalWorkspaceTabAdapter.RoutePayload] = [:]

    public init(
        panelWidth: CGFloat = 400,
        threadID: String? = nil,
        restorationState: CodexWorkspaceTabRestorationState? = nil
    ) {
        self.panelWidth = panelWidth
        self.workspaceTabs = restorationState.map(CodexWorkspaceTabs.init(restoring:))
            ?? CodexWorkspaceTabs()
        let trimmedThreadID = threadID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.threadID = trimmedThreadID?.isEmpty == true ? nil : trimmedThreadID
        indexRestoredTerminalRoutes()
    }

    public var workspaceTabRestorationState: CodexWorkspaceTabRestorationState {
        workspaceTabs.restorationState
    }

    /// Reconciles the Files adapter without publishing when registration
    /// rediscovered the session that is already installed.
    @discardableResult
    package func reconcileFilesSession(_ session: CodexFilesSession?) -> Bool {
        guard filesSession !== session else { return false }
        filesSession = session
        return true
    }

    public func applyWorkspaceTabRestoration(
        _ restorationState: CodexWorkspaceTabRestorationState
    ) {
        filesSession = nil
        workspaceTabs.apply(restoration: restorationState)
        restoredTerminalPayloads.removeAll()
        indexRestoredTerminalRoutes()
    }

    public var isAgentPanelOpen: Bool {
        get { workspaceTabs.snapshot.topology.right.isOpen }
        set { workspaceTabs.setOpen(newValue) }
    }

    public var isBottomPanelOpen: Bool {
        get { workspaceTabs.snapshot.topology.bottom.isOpen }
        set { workspaceTabs.setOpen(newValue, placement: .bottom) }
    }

    public var isAnyWorkspacePanelOpen: Bool {
        isAgentPanelOpen || isBottomPanelOpen
    }

    public var hasOpenTools: Bool {
        !terminalSessions.isEmpty || !browserSessions.isEmpty || filesSession != nil
            || workspaceTabs.hasOpenWorkspaceTabs
    }

    func agentTabs(sideChat: CodexSideChatState? = nil) -> [CodexAgentPanelTab] {
        var tabs: [CodexAgentPanelTab] = []
        if let sideChat { tabs.append(.sideChat(sideChat)) }
        return tabs
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
        let tabID = workspaceTabs.open(
            terminalAdapter(for: session, placement: placement),
            from: focus ? .commandMenu : .background,
            placement: placement,
            focus: focus
        )
        terminalTabIDs[session.id] = tabID
        return session.id
    }

    public func terminalTabID(for terminalID: String) -> CodexWorkspaceTabID? {
        terminalTabIDs[terminalID]
    }

    package var terminalWorkspaceTabAdapters: [any CodexWorkspaceTabAdapter] {
        let live = terminalSessions.map { session in
            let placement = terminalTabIDs[session.id]
                .flatMap { workspaceTabs.placement(of: $0) }
                ?? .bottom
            return terminalAdapter(for: session, placement: placement)
        }
        let lazy = restoredTerminalPayloads.sorted {
            $0.key.rawValue.uuidString < $1.key.rawValue.uuidString
        }.compactMap { tabID, payload -> CodexLazyTerminalWorkspaceTabAdapter? in
            guard !terminalSessions.contains(where: { $0.id == restoredTerminalID(payload) }) else { return nil }
            return CodexLazyTerminalWorkspaceTabAdapter(
                payload: payload,
                placement: workspaceTabs.placement(of: tabID) ?? .bottom,
                materialize: { [weak self] in self?.materializeRestoredTerminal(tabID: tabID, payload: payload) },
                onClose: { [weak self] in self?.removeRestoredTerminal(tabID: tabID) },
                onReopen: { [weak self] in self?.restoreRestoredTerminal(tabID: tabID, payload: payload) }
            )
        }
        return live + lazy
    }

    public func closeTerminal(id: String) {
        if let tabID = terminalTabIDs[id] {
            workspaceTabs.close(tabID)
        } else {
            removeTerminalSession(id: id)
        }
    }

    private func removeTerminalSession(id: String) {
        terminalSessions.removeAll { $0.id == id }
        terminalTabIDs.removeValue(forKey: id)
        restoredTerminalPayloads = restoredTerminalPayloads.filter { restoredTerminalID($0.value) != id }
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
            },
            onReopen: { [weak self] tabID in
                guard let self,
                      !self.terminalSessions.contains(where: { $0.id == session.id }) else { return }
                self.terminalSessions.append(session)
                self.terminalTabIDs[session.id] = tabID
            }
        )
    }

    private func indexRestoredTerminalRoutes() {
        for instance in workspaceTabs.snapshot.instances {
            guard let route = instance.durableRoute,
                  let payload = CodexTerminalWorkspaceTabAdapter.routePayload(from: route)
            else { continue }
            restoredTerminalPayloads[instance.id] = payload
            nextTerminalNumber = max(nextTerminalNumber, payload.ordinal + 1)
        }
    }

    private func restoredTerminalID(
        _ payload: CodexTerminalWorkspaceTabAdapter.RoutePayload
    ) -> String {
        CodexTerminalIdentity(
            threadID: payload.threadID,
            worktreePath: payload.worktreePath,
            ordinal: payload.ordinal
        ).rawValue
    }

    private func materializeRestoredTerminal(
        tabID: CodexWorkspaceTabID,
        payload: CodexTerminalWorkspaceTabAdapter.RoutePayload
    ) -> CodexTerminalSession? {
        let id = restoredTerminalID(payload)
        if let existing = terminalSessions.first(where: { $0.id == id }) {
            terminalTabIDs[id] = tabID
            return existing
        }
        guard let session = CodexTerminalWorkspaceTabAdapter.restoredLocalSession(
            from: CodexWorkspaceTabRoute(
                adapterID: "codex.terminal",
                version: 1,
                resourceID: id,
                payload: (try? JSONEncoder().encode(payload)) ?? Data()
            )
        ) else { return nil }
        terminalSessions.append(session)
        terminalTabIDs[id] = tabID
        return session
    }

    private func removeRestoredTerminal(tabID: CodexWorkspaceTabID) {
        guard let payload = restoredTerminalPayloads.removeValue(forKey: tabID) else { return }
        removeTerminalSession(id: restoredTerminalID(payload))
    }

    private func restoreRestoredTerminal(
        tabID: CodexWorkspaceTabID,
        payload: CodexTerminalWorkspaceTabAdapter.RoutePayload
    ) {
        restoredTerminalPayloads[tabID] = payload
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
        openFilePreview(
            fileURL: fileURL,
            ref: ref,
            opener: .transcript,
            placement: nil,
            focus: true
        )
    }

    /// Typed-request-friendly file opening. The resource request chooses the
    /// opener/placement while the Files adapter still owns preview identity and
    /// replacement semantics.
    @discardableResult
    public func openFilePreview(
        fileURL: URL,
        ref: String? = nil,
        opener: CodexWorkspaceTabOpener,
        placement: CodexWorkspaceTabPlacement? = nil,
        focus: Bool = true
    ) -> CodexWorkspaceTabID {
        workspaceTabs.open(
            CodexFilePreviewWorkspaceTabAdapter(fileURL: fileURL, ref: ref),
            from: opener,
            placement: placement,
            focus: focus
        )
    }

    /// Tear down every live session. Called when the store evicts this chat or
    /// the chat is closed/deleted.
    public func purge() {
        browserSessions.forEach { $0.close() }
        browserSessions.removeAll()
        terminalSessions.removeAll()
        filesSession = nil
        terminalTabIDs.removeAll()
        restoredTerminalPayloads.removeAll()
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
