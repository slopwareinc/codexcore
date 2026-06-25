import AppKit
import SwiftUI
import Observation
import CodexCore
import CodexCoreUI

func defaultWorkspacePath() -> String {
    let current = FileManager.default.currentDirectoryPath
    if current != "/" { return current }
    return FileManager.default.homeDirectoryForCurrentUser.path
}

@MainActor
@Observable
final class CodexChatModel {
    typealias ConnectionState = CodexConnectionState
    typealias Message = CodexChatMessage
    typealias Activity = CodexActivity

    var workspacePath = defaultWorkspacePath()
    var apiKey = ""
    var themePreset: CodexAgentThemePreset = .officialDark
    private(set) var gitBranch: String?
    private(set) var accountRateLimitsSnapshot: CodexSchemaRateLimitSnapshot?

    private var codex: Codex?
    var authSession = CodexAuthSession()
    let threadSession = CodexThreadSession()
    private var loginTask: Task<Void, Never>?
    var threadListSession = CodexThreadListSession(currentWorkspacePath: defaultWorkspacePath())
    var sidebarNavigationSession = CodexSidebarNavigationSession(currentWorkspacePath: defaultWorkspacePath())
    var pinnedThreadIDs = CodexPinnedThreadStorage.load()
    var configurationSession = CodexChatConfigurationSession()
    var composerSession = CodexComposerStateSession()
    var activityLog = CodexActivityLogSession()
    var structuredPanelDismissalState = CodexStructuredPanelDismissalState()
    let runtimeSession = CodexChatRuntimeSession()
    let promptRuntime = CodexPromptRuntimeSession()
    private let mentionSearchSession = CodexMentionSearchSession()
    private var terminalSession: CodexCommandExecSession?
    private var terminalOutputTask: Task<Void, Never>?
    private var terminalCompletionTask: Task<Void, Never>?

    var isBottomTerminalVisible = false
    var bottomTerminalHeight: CGFloat = 280
    var bottomTerminalText = ""
    var bottomTerminalStatus = "Idle"
    var isBottomTerminalRunning = false

    func connect() async {
        guard authSession.beginConnecting() else { return }

        resetSessionState()
        startInteractivePromptEventListener()
        do {
            // `.ask` publishes approvals and user-input questions to
            // `codex.store.pendingApprovals` / `pendingUserInput` and suspends
            // the server reply until this app answers them.
            let config = CodexConfig(
                cwd: workspacePath,
                environment: ["CODEX_HOME": defaultCodexHome()],
                clientName: "codex_swiftui_example",
                clientTitle: "Codex SwiftUI Example",
                clientVersion: "1.0.0",
                approvalPolicy: .ask
            )
            let codex = try await Codex(config: config, serverRequestHandler: { [weak self] request in
                // MCP elicitations are not covered by the approval policy;
                // bridge them into the interactive prompt UI. Everything else
                // falls through (nil) to the SDK's `.ask` flow.
                guard let self else { return nil }
                return await self.promptRuntime.handleMCPServerElicitationRequest(request)
            })
            self.codex = codex
            runtimeSession.bindHost(
                currentThreadID: { [weak self] in self?.currentThreadID },
                store: { [weak self] in self?.codex?.store },
                applyResult: { [weak self] result in self?.apply(result) },
                applySideChatUpdate: { [weak self] update in self?.applySideChat(update) }
            )
            runtimeSession.consumeGlobalNotifications(from: codex)
            bindApprovalStore(from: codex.store)
            let server = codex.metadata.serverInfo?.name ?? "Codex"
            authSession.connected(server: server)

            do {
                let account = try await codex.account(refreshToken: false)
                let authCheck = authSession.applyAccount(account)
                if let activity = authCheck.activity {
                    appendActivity(activity)
                }
                if !authCheck.shouldContinue {
                    return
                }
            } catch {
                appendActivity(authSession.accountCheckSkipped(message: friendlyError(error)))
            }

            try await refreshConnectedSession(using: codex)
        } catch {
            appendActivity(authSession.connectionFailed(message: friendlyError(error)))
        }
    }

    func disconnect() async {
        await stopBottomTerminalSession()
        runtimeSession.reset()
        promptRuntime.reset()
        mentionSearchSession.reset()
        loginTask?.cancel()
        await promptRuntime.cancelAllPrompts()
        loginTask = nil
        threadSession.reset()
        accountRateLimitsSnapshot = nil
        gitBranch = nil
        let codex = self.codex
        self.codex = nil
        await codex?.close()
        appendActivity(authSession.disconnected())
    }

    func loginWithAPIKey() async {
        guard let codex else { return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try await codex.loginAPIKey(key)
            apiKey = ""
            appendActivity(authSession.apiKeyAccepted())
            try await refreshConnectedSession(using: codex)
        } catch {
            appendActivity(authSession.apiKeyFailed(message: friendlyError(error)))
        }
    }

    func startDeviceCodeLogin() async {
        guard let codex else { return }
        do {
            let handle = try await codex.loginChatGPTDeviceCode()
            appendActivity(authSession.deviceCodeStarted(url: handle.verificationUrl, code: handle.userCode))
            loginTask?.cancel()
            loginTask = Task { [weak self] in
                do {
                    _ = try await handle.wait()
                    await self?.finishDeviceCodeLogin()
                } catch {
                    await MainActor.run {
                        guard let self else { return }
                        self.appendActivity(self.authSession.deviceCodeEnded(message: self.friendlyError(error)))
                    }
                }
            }
        } catch {
            appendActivity(authSession.deviceCodeFailed(message: friendlyError(error)))
        }
    }

    func sendDraft() async {
        let route = CodexTurnSubmissionSession.consumeDraft(
            composerSession: &composerSession,
            canSendFollowUp: canSendFollowUp,
            isGoalPursuitEnabled: isGoalPursuitEnabled
        )

        switch route {
        case .none:
            return
        case .followUp(let prompt):
            await sendFollowUp(prompt: prompt)
        case .goal(let submission):
            await sendGoalDraft(submission)
        case .turn(let submission):
            let didStart = await runtimeSession.submitMainTurn(
                submission,
                start: {
                    let thread = try await self.ensureThread()
                    return try await thread.turn(submission.turnInput, configuration: self.turnLaunchConfiguration)
                },
                onActivity: { [weak self] activity in self?.appendActivity(activity) },
                errorMessage: Self.friendlyErrorMessage
            )
            if !didStart {
                composerSession.restore(submission)
            }
        }
    }

    /// Handles send while a turn is already running: steer it immediately or
    /// queue the message for the next turn, per `followUpBehavior`.
    private func sendFollowUp(prompt: String) async {
        let activeTurn = runtimeSession.activeTurn
        switch runtimeSession.prepareFollowUp(
            prompt: prompt,
            composerSession: &composerSession,
            followUpBehavior: followUpBehavior,
            canSteer: activeTurn != nil
        ) {
        case .queued(_, let activity):
            appendActivity(activity)
        case .steer(let prompt, let activity):
            appendActivity(activity)
            guard let activeTurn else { return }
            do {
                _ = try await activeTurn.steer(prompt)
            } catch {
                appendActivity(CodexTurnSubmissionSession.failSteeredFollowUp(
                    prompt: prompt,
                    message: friendlyError(error),
                    composerSession: &composerSession
                ))
            }
        }
    }

    /// Sends the next queued follow-up as a fresh turn. Called after a turn
    /// finishes; messages were already rendered when they were queued.
    private func flushQueuedFollowUps() {
        guard let submission = runtimeSession.dequeueQueuedFollowUp(
            composerSession: &composerSession,
            isSending: isSending
        ) else {
            return
        }
        appendActivity(submission.activity)

        Task { [weak self] in
            guard let self else { return }
            do {
                let thread = try await ensureThread()
                let handle = try await thread.turn(submission.input, configuration: turnLaunchConfiguration)
                await MainActor.run {
                    self.runtimeSession.startMainTurn(handle)
                    self.runtimeSession.consumeMainTurn(handle)
                }
            } catch {
                await MainActor.run {
                    self.appendActivity(self.runtimeSession.failQueuedFollowUp(
                        submission,
                        message: self.friendlyError(error),
                        composerSession: &self.composerSession
                    ))
                }
            }
        }
    }

    private func sendGoalDraft(_ submission: CodexComposerSubmission) async {
        let didStart = await runtimeSession.submitGoal(
            submission,
            start: {
                let thread = try await self.ensureThread()
                let response = try await thread.setGoal(objective: submission.prompt, status: .active)
                return response.goal
            },
            onActivity: { [weak self] activity in self?.appendActivity(activity) },
            errorMessage: Self.friendlyErrorMessage
        )
        if !didStart {
            composerSession.restore(submission)
        }
    }

    func setGoalPursuitEnabled(_ enabled: Bool) {
        guard let change = runtimeSession.setGoalPursuitEnabled(enabled) else { return }
        if let activity = change.activity {
            appendActivity(.notice, title: activity.title, detail: activity.detail)
        }
        if change.shouldClearRemoteGoal {
            Task { await clearCurrentGoal() }
        }
    }

    func handleComposerAddMenuRoute(_ route: CodexComposerAddMenuRoute) {
        for activity in route.activities {
            appendActivity(activity)
        }
        guard route.isEnabled else { return }
        for action in route.hostActions {
            handleComposerAddMenuHostAction(action)
        }
    }

    func handleComposerDictationRoute(_ route: CodexComposerDictationRoute) {
        for activity in route.activities {
            appendActivity(activity)
        }
        runtimeSession.append(route.noticeMessage)
    }

    func handleWorktreeHandoffCompletion(_ completion: CodexWorktreeHandoffCompletion) {
        appendActivity(completion.activity)
        runtimeSession.append(CodexWorktreeHandoffTranscriptEntry(completion: completion).message)
    }

    func clearComposerChip(_ kind: CodexComposerChipKind) {
        switch kind {
        case .goal:
            setGoalPursuitEnabled(false)
        case .plan:
            configurationSession.setPlanModeEnabled(false)
        }
    }

    private func handleComposerAddMenuHostAction(_ action: CodexComposerAddMenuHostAction) {
        switch action {
        case .attachFilesAndFolders:
            appendActivity(.notice, title: "Files unavailable", detail: "File and folder attachment is not wired in the native composer yet.")
        case .enableGoalPursuit:
            setGoalPursuitEnabled(true)
        case .enablePlanMode:
            configurationSession.setPlanModeEnabled(true)
        case .openPlugins:
            selectAppRoute(.plugins)
        case .openFilesAndChats:
            selectAppRoute(.search)
        }
    }

    func clearCurrentGoal() async {
        guard let thread = threadSession.currentThread, runtimeSession.hasActiveGoal else {
            runtimeSession.resetGoal()
            return
        }
        do {
            let response = try await thread.clearGoal()
            if response.cleared {
                clearGoalState()
                appendActivity(.notice, title: "Goal cleared", detail: "Thread goal removed")
            }
        } catch {
            appendActivity(.notice, title: "Goal clear failed", detail: friendlyError(error))
            runtimeSession.restorePursuitAfterClearFailure()
        }
    }

    private func finishDeviceCodeLogin() async {
        appendActivity(authSession.deviceCodeCompleted())
        do {
            guard let codex else { return }
            try await refreshConnectedSession(using: codex)
        } catch {
            appendActivity(.turn, title: "Session refresh failed", detail: friendlyError(error))
        }
    }

    private func refreshConnectedSession(using codex: Codex) async throws {
        await refreshStartupCatalogs(using: codex)
        await refreshRecentChats(using: codex)
        try await refreshRateLimits(using: codex)
        refreshGitBranch()
    }

    private func refreshRateLimits(using codex: Codex) async throws {
        let response = try await codex.rateLimits()
        accountRateLimitsSnapshot = response.rateLimits
    }

    private func refreshGitBranch() {
        let path = workspacePath
        Task {
            gitBranch = await Self.gitBranch(in: path)
        }
    }

    private func syncAccountMetadata() {
        accountRateLimitsSnapshot = codex?.store.accountRateLimits ?? accountRateLimitsSnapshot
    }

    nonisolated private static func gitBranch(in path: String) async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let branch = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return branch?.isEmpty == false ? branch : nil
            } catch {
                return nil
            }
        }.value
    }

    private func refreshSlashCommands(forceReload: Bool = false) async {
        guard let codex else { return }
        await refreshSlashCommands(using: codex, forceReload: forceReload)
    }

    private func refreshStartupCatalogs(using codex: Codex) async {
        var session = configurationSession
        let activities = await session.refreshStartupCatalogs(
            using: codex,
            cwds: [workspacePath],
            errorMessage: Self.friendlyErrorMessage
        )
        configurationSession = session
        appendConfigurationActivities(activities)
    }

    private func refreshSlashCommands(using codex: Codex, forceReload: Bool = false) async {
        var session = configurationSession
        let activity = await session.refreshSlashCommands(
            using: codex,
            cwds: [workspacePath],
            forceReload: forceReload,
            errorMessage: Self.friendlyErrorMessage
        )
        configurationSession = session
        appendConfigurationActivity(activity)
    }

    func refreshRecentChats() async {
        guard let codex else { return }
        await refreshRecentChats(using: codex)
    }

    private func refreshRecentChats(using codex: Codex) async {
        var session = threadListSession
        let activity = await session.refreshRecentChats(
            using: codex,
            currentWorkspacePath: workspacePath,
            errorMessage: Self.friendlyErrorMessage
        )
        threadListSession = session
        if let activity {
            appendActivity(.notice, title: activity.title, detail: activity.detail)
        }
    }

    func selectAppRoute(_ route: CodexAppRoute) {
        sidebarNavigationSession.selectRoute(route)
        if route == .plugins {
            Task { await refreshPlugins() }
        }
    }

    func prepareAutomationChat(prompt: String) async {
        sidebarNavigationSession.selectRoute(.chat)
        clearThreadState()
        composerSession.draft = prompt
        appendActivity(.notice, title: "Automation draft", detail: "Prepared automation chat")
        await refreshRecentChats()
    }

    func dismissSearchRoute() {
        sidebarNavigationSession.dismissSearchOverlay()
    }

    func toggleSidebarCollapsed() {
        sidebarNavigationSession.toggleCollapsed()
    }

    func toggleSidebarProject(_ workspacePath: String) {
        sidebarNavigationSession.toggleProject(workspacePath)
    }

    func selectSidebarProject(_ path: String) async {
        sidebarNavigationSession.selectProject(path)
        await switchWorkspace(to: path)
    }

    func startNewChat(inProject path: String) async {
        sidebarNavigationSession.selectProject(path)
        if CodexProjectSummary.normalizedPath(path) != CodexProjectSummary.normalizedPath(workspacePath) {
            await switchWorkspace(to: path)
        }
        await startNewChat()
    }

    func selectSidebarChat(_ chat: CodexThreadSummary) async {
        sidebarNavigationSession.selectChat(chat.id, workspacePath: chat.workspacePath)
        if let path = chat.workspacePath,
           CodexProjectSummary.normalizedPath(path) != CodexProjectSummary.normalizedPath(workspacePath) {
            await switchWorkspace(to: path)
        }
        await resumeChat(id: chat.id)
    }

    func switchWorkspace(to path: String) async {
        let normalized = CodexProjectSummary.normalizedPath(path)
        guard !normalized.isEmpty else { return }
        guard normalized != CodexProjectSummary.normalizedPath(workspacePath) else {
            sidebarNavigationSession.syncCurrentWorkspace(workspacePath, currentThreadID: currentThreadID)
            return
        }

        workspacePath = normalized
        sidebarNavigationSession.syncCurrentWorkspace(workspacePath, currentThreadID: nil)
        clearThreadState()
        appendActivity(.notice, title: "Switched project", detail: normalized)

        guard let codex else {
            threadListSession.refreshProjects(currentWorkspacePath: workspacePath)
            return
        }

        await refreshSlashCommands(using: codex)
        await refreshRecentChats(using: codex)
    }

    func startNewChat() async {
        sidebarNavigationSession.startNewChat(workspacePath: workspacePath)
        clearThreadState()
        guard codex != nil else { return }
        await refreshRecentChats()
    }

    func resumeChat(id threadID: String) async {
        guard let codex else { return }
        guard !threadSession.isCurrentThread(id: threadID) else { return }
        clearThreadState()
        do {
            let resumedThread = try await threadSession.resumeThread(
                id: threadID,
                using: codex,
                configuration: threadLaunchConfiguration
            )
            await hydrateThreadHistory(for: resumedThread, using: codex)
            await refreshGoal(for: resumedThread)
            sidebarNavigationSession.selectChat(threadID, workspacePath: workspacePath)
            appendActivity(.notice, title: "Resumed chat", detail: threadID)
            await refreshRecentChats(using: codex)
        } catch {
            appendMessage(.system, "Failed to resume chat: \(friendlyError(error))")
            appendActivity(.notice, title: "Resume failed", detail: friendlyError(error))
        }
    }

    func searchChats(query: String) async {
        var session = threadListSession
        let activity = await session.searchChats(query: query, using: codex, errorMessage: Self.friendlyErrorMessage)
        threadListSession = session
        if let activity {
            appendActivity(.notice, title: activity.title, detail: activity.detail)
        }
    }

    func clearSearchResults() {
        threadListSession.clearSearch()
    }

    func appendPaletteNotice(title: String, detail: String) {
        appendActivity(.notice, title: title, detail: detail)
    }

    func refreshSlashCommandsFromPalette() {
        Task { await refreshSlashCommands(forceReload: true) }
    }

    func refreshMCPServers() async {
        guard let codex else {
            runtimeSession.integrationCatalogSession.requireMCPConnection(message: "Connect to Codex before inspecting MCP servers.")
            return
        }

        var session = runtimeSession.integrationCatalogSession
        let activity = await session.refreshMCPServers(
            using: codex,
            threadID: currentThreadID,
            errorMessage: Self.friendlyErrorMessage
        )
        runtimeSession.integrationCatalogSession = session
        appendIntegrationActivity(activity)
    }

    func refreshPlugins() async {
        guard let codex else {
            runtimeSession.integrationCatalogSession.requirePluginConnection(message: "Connect to Codex before inspecting plugins.")
            return
        }

        var session = runtimeSession.integrationCatalogSession
        let activity = await session.refreshPlugins(
            using: codex,
            cwds: [workspacePath],
            errorMessage: Self.friendlyErrorMessage
        )
        runtimeSession.integrationCatalogSession = session
        appendIntegrationActivity(activity)
    }

    func pinCurrentChat() {
        guard let threadID = currentThreadID else {
            appendActivity(.notice, title: "Pin unavailable", detail: "No active chat to pin")
            return
        }
        setThreadPinned(threadID, pinned: !pinnedThreadIDs.contains(threadID))
    }

    func toggleSidebarChatPin(_ chat: CodexThreadSummary) {
        setThreadPinned(chat.id, pinned: !pinnedThreadIDs.contains(chat.id))
    }

    func archiveSidebarChat(_ chat: CodexThreadSummary) async {
        guard let codex else { return }
        do {
            _ = try await codex.threadArchive(chat.id)
            setThreadPinned(chat.id, pinned: false, announces: false)
            removeChatFromSidebar(chat.id)
            if chat.id == currentThreadID {
                clearThreadState()
                sidebarNavigationSession.syncCurrentWorkspace(workspacePath, currentThreadID: nil)
            }
            appendActivity(.notice, title: "Archived chat", detail: chat.id)
            await refreshRecentChats(using: codex)
        } catch {
            appendActivity(.notice, title: "Archive failed", detail: friendlyError(error))
        }
    }

    func addAutomationForCurrentChat() {
        guard let threadID = currentThreadID else {
            appendActivity(.notice, title: "Automation unavailable", detail: "No active chat to automate")
            return
        }
        composerSession.draft = CodexThreadLifecycleActionModel.addAutomationDraftPrompt(
            threadID: threadID,
            threadTitle: currentChatTitle,
            workspacePath: workspacePath
        )
        selectAppRoute(.chat)
        appendActivity(.notice, title: "Automation draft", detail: "Prepared automation draft for \(currentChatTitle)")
    }

    func openCurrentChatInNewWindow() {
        guard let threadID = currentThreadID else {
            appendActivity(.notice, title: "Open window unavailable", detail: "No active chat to open")
            return
        }
        appendActivity(CodexThreadLifecycleActionModel.openInNewWindowUnavailableActivity(threadID: threadID))
    }

    func resolveApprovalPrompt(id: String, approved: Bool) {
        Task { [weak self] in
            guard let self else { return }
            if let activity = await promptRuntime.resolveApprovalPrompt(id: id, approved: approved, using: codex) {
                appendActivity(.notice, title: activity.title, detail: activity.detail)
            }
        }
    }

    func submitInteractivePrompt(id: String, answers: [String: String]) {
        Task { [weak self] in
            guard let self else { return }
            _ = await promptRuntime.submitInteractivePrompt(
                id: id,
                answers: answers,
                using: codex
            )
        }
    }

    func acceptInteractivePrompt(id: String) {
        Task { [weak self] in
            guard let self else { return }
            await promptRuntime.acceptInteractivePrompt(id: id)
        }
    }

    func declineInteractivePrompt(id: String) {
        Task { [weak self] in
            guard let self else { return }
            _ = await promptRuntime.declineInteractivePrompt(
                id: id,
                using: codex
            )
        }
    }

    func resumeSearchResult(_ result: CodexThreadSearchResult) async {
        let workspace = result.thread.workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let workspace, !workspace.isEmpty {
            let normalized = CodexProjectSummary.normalizedPath(workspace)
            if normalized != CodexProjectSummary.normalizedPath(workspacePath) {
                workspacePath = normalized
                sidebarNavigationSession.syncCurrentWorkspace(workspacePath, currentThreadID: nil)
                clearThreadState()
                appendActivity(.notice, title: "Switched project", detail: normalized)
            }
        }
        await resumeChat(id: result.thread.id)
    }

    func forkCurrentChat() async {
        guard let codex else { return }
        do {
            guard let fork = try await threadSession.forkCurrentThread(
                using: codex,
                configuration: threadLaunchConfiguration
            ) else {
                return
            }
            clearThreadState(keepCurrentThread: true)
            await hydrateThreadHistory(for: fork.thread, using: codex)
            sidebarNavigationSession.selectChat(fork.thread.id, workspacePath: workspacePath)
            appendActivity(.notice, title: "Forked chat", detail: fork.sourceID)
            await refreshRecentChats(using: codex)
        } catch {
            appendMessage(.system, "Failed to fork chat: \(friendlyError(error))")
            appendActivity(.notice, title: "Fork failed", detail: friendlyError(error))
        }
    }

    func archiveCurrentChat() async {
        guard let codex else { return }
        do {
            guard let archivedID = try await threadSession.archiveCurrentThread(using: codex) else { return }
            setThreadPinned(archivedID, pinned: false, announces: false)
            removeChatFromSidebar(archivedID)
            clearThreadState()
            sidebarNavigationSession.syncCurrentWorkspace(workspacePath, currentThreadID: nil)
            appendActivity(.notice, title: "Archived chat", detail: archivedID)
            await refreshRecentChats(using: codex)
        } catch {
            appendActivity(.notice, title: "Archive failed", detail: friendlyError(error))
        }
    }

    func renameCurrentChat(to name: String) async {
        guard let thread = threadSession.currentThread else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await thread.setName(trimmed)
            renameChatInSidebar(thread.id, title: trimmed)
            appendActivity(.notice, title: "Renamed chat", detail: trimmed)
            await refreshRecentChats()
        } catch {
            appendActivity(.notice, title: "Rename failed", detail: friendlyError(error))
        }
    }

    func compactCurrentChat() async {
        guard let thread = threadSession.currentThread else {
            appendActivity(.notice, title: "Compact unavailable", detail: "No active chat to compact")
            return
        }
        do {
            _ = try await thread.compact()
            appendActivity(.notice, title: "Compact started", detail: "App-server is compacting this chat")
        } catch {
            appendActivity(.notice, title: "Compact failed", detail: friendlyError(error))
        }
    }

    @discardableResult
    private func ensureThread() async throws -> CodexThread {
        guard let codex else { throw CodexSDKError.runtimeNotFound }
        let result = try await threadSession.ensureThread(
            using: codex,
            configuration: threadLaunchConfiguration
        )
        if result.didStart {
            await refreshGoal(for: result.thread)
            appendActivity(.notice, title: "Thread ready", detail: "Workspace session created")
        }
        return result.thread
    }

    private func refreshGoal(for thread: CodexThread) async {
        do {
            let response = try await thread.goal()
            if let goal = response.goal {
                applyGoal(goal, turnID: nil, shouldAnnounce: false)
            } else {
                clearGoalState()
            }
        } catch {
            appendActivity(.notice, title: "Goal unavailable", detail: friendlyError(error))
        }
    }

    private func hydrateThreadHistory(for thread: CodexThread, using codex: Codex) async {
        do {
            let result = try await CodexThreadHistorySession.load(threadID: thread.id, using: codex)
            let activity = runtimeSession.applyHistoryRestore(result)
            appendActivity(activity.kind, title: activity.title, detail: activity.detail)
        } catch {
            appendActivity(.notice, title: "Transcript unavailable", detail: friendlyError(error))
            if messages.isEmpty {
                appendMessage(.system, "Unable to load prior transcript: \(friendlyError(error))")
            }
        }
    }

    @discardableResult
    private func ensureSideChatThread() async throws -> CodexThread {
        guard let codex else { throw CodexSDKError.runtimeNotFound }
        let result = try await threadSession.ensureSideChatThread(
            using: codex,
            configuration: threadLaunchConfiguration
        )
        if result.didFork {
            appendActivity(.notice, title: "Side chat ready", detail: "Forked focused branch")
        }
        return result.thread
    }

    func interrupt() async {
        if let activeTurn = runtimeSession.activeTurn {
            do {
                _ = try await activeTurn.interrupt()
                appendActivity(.turn, title: "Interrupt sent", detail: "Stopping the current turn")
            } catch {
                appendActivity(.turn, title: "Interrupt failed", detail: friendlyError(error))
            }
            return
        }

        guard let thread = threadSession.currentThread, let activeGoalTurnID = runtimeSession.activeGoalTurnID else { return }
        do {
            _ = try await thread.interrupt(turnId: activeGoalTurnID)
            appendActivity(.turn, title: "Interrupt sent", detail: "Stopping the current turn")
        } catch {
            appendActivity(.turn, title: "Interrupt failed", detail: friendlyError(error))
        }
    }

    func openSideChat() {
        let activity = runtimeSession.openSideChat()
        appendActivity(activity.kind, title: activity.title, detail: activity.detail)
    }

    func sendSideChatDraft() async {
        let prompt = composerSession.trimmedSideChatDraft
        guard !prompt.isEmpty else { return }
        composerSession.clearSideChatDraft()
        await runtimeSession.submitSideChat(
            prompt: prompt,
            start: {
                let thread = try await self.ensureSideChatThread()
                return try await thread.turn([.text(prompt)], configuration: self.turnLaunchConfiguration)
            },
            onActivity: { [weak self] activity in self?.appendActivity(activity) },
            errorMessage: Self.friendlyErrorMessage
        )
    }

    func interruptSideChat() async {
        guard let activeSideChatTurn = runtimeSession.activeSideChatTurn else { return }
        do {
            _ = try await activeSideChatTurn.interrupt()
            appendActivity(.turn, title: "Side chat interrupt sent", detail: "Stopping the side chat turn")
        } catch {
            appendActivity(.turn, title: "Side chat interrupt failed", detail: friendlyError(error))
        }
    }

    func copyChatTranscript() {
        let transcript = CodexChatUtilitySession.transcriptText(messages: messages)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)

        let detail = CodexChatUtilitySession.copiedTranscriptActivityDetail(messageCount: messages.count)
        appendActivity(.notice, title: "Copied chat", detail: detail)
    }

    func handleSlashCommand(_ command: CodexSlashCommand, presentMCPStatus: (() -> Void)? = nil) {
        let route = composerSession.routeSlashCommand(command)
        for activity in route.activities {
            appendActivity(activity)
        }
        for action in route.hostActions {
            applySlashCommandHostAction(action, presentMCPStatus: presentMCPStatus)
        }
    }

    private func applySlashCommandHostAction(
        _ action: CodexComposerSlashCommandHostAction,
        presentMCPStatus: (() -> Void)?
    ) {
        switch action {
        case .openSideChat:
            openSideChat()
        case .applyFastMode:
            applyFastCommand()
        case .cycleReasoning:
            applyReasoningCommand()
        case .showModelStatus:
            appendActivity(.notice, title: "Model", detail: "\(modelSelection.displayName) \(reasoningSelection.displayName)")
        case .showCurrentStatus:
            appendStatusPanel()
            appendActivity(.notice, title: "Status", detail: connectionState.label)
        case .forkCurrentChat:
            Task { await forkCurrentChat() }
        case .compactCurrentChat:
            Task { await compactCurrentChat() }
        case .presentMCPStatus:
            appendMCPStatusPanel()
        case .refreshMCPServers:
            Task { await refreshMCPServers() }
        }
    }

    private func apply(_ result: CodexChatNotificationPipelineResult) {
        syncAccountMetadata()
        for activity in result.activities {
            appendActivity(activity.kind, title: activity.title, detail: activity.detail)
        }
        for action in result.actions {
            switch action {
            case .refreshRecentChats:
                Task { await refreshRecentChats() }
            case .refreshSlashCommands(let forceReload):
                Task { await refreshSlashCommands(forceReload: forceReload) }
            case .flushQueuedFollowUps:
                flushQueuedFollowUps()
            }
        }
    }

    private func applySideChat(_ update: CodexSideChatSessionUpdate) {
        if let activity = update.activity {
            appendActivity(activity.kind, title: activity.title, detail: activity.detail)
        }
    }

    // MARK: - Goal State

    private func applyGoal(_ goal: ThreadGoal, turnID: String?, shouldAnnounce: Bool = true) {
        if let activity = runtimeSession.applyGoal(goal, turnID: turnID, shouldAnnounce: shouldAnnounce) {
            appendActivity(activity)
        }
    }

    private func clearGoalState() {
        runtimeSession.resetGoal()
    }

    private func bindApprovalStore(from store: CodexCoreStore) {
        promptRuntime.bindApprovalStore(from: store) { [weak self] activity in
            guard let self else { return }
            appendActivity(.notice, title: activity.title, detail: activity.detail)
        }
    }

    private func startInteractivePromptEventListener() {
        promptRuntime.startInteractivePromptEventListener { [weak self] activity in
            self?.appendActivity(.notice, title: activity.title, detail: activity.detail)
        }
    }

    private func appendMessage(_ role: Message.Role, _ text: String, detail: String? = nil) {
        runtimeSession.appendMessage(role, text, detail: detail)
    }

    private func appendStatusPanel() {
        let itemID = "slash-status-\(UUID().uuidString)"
        runtimeSession.append(CodexStatusPanelModel(
            context: statusSummaryContext,
            rateLimits: accountRateLimitsSnapshot
        ).message(itemID: itemID))
    }

    private func appendMCPStatusPanel() {
        let itemID = "slash-mcp-\(UUID().uuidString)"
        runtimeSession.append(CodexMCPStatusPanelModel(
            servers: mcpServers,
            isLoading: isLoadingMCPServers,
            errorMessage: mcpErrorMessage
        ).message(itemID: itemID))
    }

    func dismissTranscriptMessage(_ id: UUID) {
        structuredPanelDismissalState.dismiss(messageID: id)
    }

    private func appendActivity(_ kind: Activity.Kind, title: String, detail: String) {
        activityLog.append(kind, title: title, detail: detail)
    }

    private func appendActivity(_ activity: Activity) {
        appendActivity(activity.kind, title: activity.title, detail: activity.detail)
    }

    private func appendConfigurationActivity(_ activity: CodexChatConfigurationActivity) {
        appendActivity(.notice, title: activity.title, detail: activity.detail)
    }

    private func appendConfigurationActivities(_ activities: [CodexChatConfigurationActivity]) {
        for activity in activities {
            appendConfigurationActivity(activity)
        }
    }

    private func appendIntegrationActivity(_ activity: CodexIntegrationCatalogActivity) {
        appendActivity(.notice, title: activity.title, detail: activity.detail)
    }

    private func friendlyError(_ error: Error) -> String {
        Self.friendlyErrorMessage(error)
    }

    nonisolated private static func friendlyErrorMessage(_ error: Error) -> String {
        let described = String(describing: error)
        return described.count > 200 ? String(described.prefix(200)) + "…" : described
    }

    private func applyFastCommand() {
        let activity = configurationSession.applyFastCommand()
        appendActivity(.notice, title: activity.title, detail: activity.detail)
    }

    private func applyReasoningCommand() {
        if let activity = configurationSession.cycleReasoning() {
            appendActivity(.notice, title: activity.title, detail: activity.detail)
        }
    }

    private var statusSummaryContext: CodexChatStatusSummaryContext {
        CodexChatStatusSummaryContext(
            connectionLabel: connectionState.label,
            workspacePath: workspacePath,
            currentThreadID: currentThreadID,
            modelDisplayName: modelSelection.displayName,
            reasoningDisplayName: reasoningSelection.displayName,
            approvalDisplayName: approvalSelection.displayName,
            messageCount: messages.count,
            isSideChatOpen: sideChat != nil,
            activeSubagentCount: subagents.filter { $0.status == .running }.count,
            subagentCount: subagents.count,
            tokenUsageSummary: currentTokenUsageSummary,
            rateLimitSummary: accountRateLimitsSnapshot.map(CodexRateLimitPresentation.summary),
            gitBranch: gitBranch
        )
    }

    var rateLimitBannerMessage: String? {
        guard let accountRateLimitsSnapshot else { return nil }
        return CodexRateLimitPresentation.bannerMessage(for: accountRateLimitsSnapshot)
    }

    var workspaceSummaryContext: CodexWorkspaceSummaryContext {
        CodexWorkspaceSummaryContext(
            workspacePath: workspacePath,
            gitBranch: gitBranch,
            turnDiff: currentDiff
        )
    }

    private var currentTokenUsageSummary: String? {
        guard let threadID = currentThreadID,
              let usage = codex?.store.threadSnapshot(id: threadID)?.turns.last?.usage else {
            return nil
        }
        return CodexChatUtilitySession.tokenUsageSummary(usage)
    }

    // MARK: - @-mention file search

    func updateMentionQuery(_ query: String?) {
        mentionSearchSession.updateQuery(
            query,
            codex: codex,
            roots: [workspacePath],
            onResults: { [weak self] files in self?.composerSession.setMentionResults(files) },
            onClear: { [weak self] in self?.composerSession.clearMentionResults() }
        )
    }

    func selectMention(_ result: FuzzyFileSearchResult) {
        composerSession.selectMention(result)
        appendActivity(.notice, title: "Mentioned file", detail: result.path)
    }

    // MARK: - File change undo

    func undoFileChange(_ change: CodexChatMessage.FileChange) {
        guard let plan = CodexFileChangeUndoSession.plan(for: change, workspacePath: workspacePath) else {
            appendActivity(CodexFileChangeUndoSession.unavailableActivity)
            return
        }

        Task { [weak self] in
            guard let self, let codex else { return }
            do {
                _ = try await codex.execCommand(plan.command, cwd: plan.cwd)
                await MainActor.run {
                    self.appendActivity(CodexFileChangeUndoSession.successActivity(relativePath: plan.relativePath))
                }
            } catch {
                await MainActor.run {
                    self.appendActivity(CodexFileChangeUndoSession.failureActivity(message: self.friendlyError(error)))
                }
            }
        }
    }

    func reviewFileChange(_ change: CodexChatMessage.FileChange) {
        guard let codex, let threadID = currentThreadID else {
            appendActivity(.notice, title: "Review unavailable", detail: "Connect and start a thread first")
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await codex.startReview(
                    threadID: threadID,
                    target: CodexSchemaReviewTarget(.dictionary([
                        "itemIds": .array([.string(change.itemID)])
                    ])),
                    delivery: .inline
                )
                await MainActor.run {
                    self.appendActivity(.notice, title: "Review started", detail: change.displayPath)
                }
            } catch {
                await MainActor.run {
                    self.appendActivity(.notice, title: "Review failed", detail: self.friendlyError(error))
                }
            }
        }
    }

    private func clearThreadState(keepCurrentThread: Bool = false) {
        if !keepCurrentThread {
            threadSession.reset()
        }
        runtimeSession.resetThreadState()
        composerSession.clearThreadState()
        promptRuntime.reset()
        Task { await promptRuntime.cancelAllPrompts() }
    }

    private func resetSessionState() {
        Task { await stopBottomTerminalSession() }
        runtimeSession.cancelGlobalNotifications()
        promptRuntime.reset()
        mentionSearchSession.reset()
        structuredPanelDismissalState = CodexStructuredPanelDismissalState()
        loginTask?.cancel()
        loginTask = nil
        Task { await promptRuntime.cancelAllPrompts() }
        codex = nil
        authSession.resetAuthentication()
        threadListSession.reset(currentWorkspacePath: workspacePath)
        sidebarNavigationSession.syncCurrentWorkspace(workspacePath, currentThreadID: nil)
        runtimeSession.integrationCatalogSession.reset()
        configurationSession.reset()
        clearThreadState()
    }

    private func setThreadPinned(_ threadID: String, pinned: Bool, announces: Bool = true) {
        if pinned {
            pinnedThreadIDs.removeAll { $0 == threadID }
            pinnedThreadIDs.insert(threadID, at: 0)
        } else {
            pinnedThreadIDs.removeAll { $0 == threadID }
        }
        CodexPinnedThreadStorage.save(pinnedThreadIDs)
        guard announces else { return }
        appendActivity(
            .notice,
            title: pinned ? "Pinned chat" : "Unpinned chat",
            detail: threadID
        )
    }

    private func renameChatInSidebar(_ threadID: String, title: String) {
        var session = threadListSession
        session.renameThread(id: threadID, title: title, currentWorkspacePath: workspacePath)
        threadListSession = session
    }

    private func removeChatFromSidebar(_ threadID: String) {
        var session = threadListSession
        session.removeThread(id: threadID, currentWorkspacePath: workspacePath)
        threadListSession = session
    }

    // MARK: - Bottom Terminal Panel

    func toggleBottomTerminalPanel() {
        isBottomTerminalVisible.toggle()
    }

    func setBottomTerminalHeight(_ height: CGFloat, maxHeight: CGFloat) {
        let minHeight: CGFloat = 140
        let clampedMax = max(minHeight, maxHeight)
        bottomTerminalHeight = min(max(height, minHeight), clampedMax)
    }

    func clearBottomTerminalOutput() {
        bottomTerminalText = ""
    }

    func openBottomTerminalDemo() async {
        guard let codex else {
            appendActivity(.notice, title: "Terminal unavailable", detail: "Connect to Codex before opening terminal output.")
            return
        }

        await stopBottomTerminalSession()

        isBottomTerminalVisible = true
        bottomTerminalText = ""
        bottomTerminalStatus = "Starting command session..."
        isBottomTerminalRunning = true

        do {
            let session = try await codex.startCommandSession(
                ["echo", "Codex terminal demo"],
                cwd: workspacePath,
                tty: false
            )
            terminalSession = session
            bottomTerminalStatus = "Running in \(workspacePath)"

            terminalOutputTask = Task { [weak self] in
                for await delta in session.outputStream {
                    await MainActor.run {
                        self?.appendTerminalDelta(delta)
                    }
                }
            }

            terminalCompletionTask = Task { [weak self] in
                do {
                    let result = try await session.wait()
                    await MainActor.run {
                        self?.finishBottomTerminalSession(result: result)
                    }
                } catch {
                    await MainActor.run {
                        self?.isBottomTerminalRunning = false
                        self?.bottomTerminalStatus = "Session failed: \(Self.friendlyErrorMessage(error))"
                    }
                }
            }
        } catch {
            isBottomTerminalRunning = false
            bottomTerminalStatus = "Failed to start session: \(friendlyError(error))"
        }
    }

    private func stopBottomTerminalSession() async {
        terminalOutputTask?.cancel()
        terminalCompletionTask?.cancel()
        terminalOutputTask = nil
        terminalCompletionTask = nil
        if let session = terminalSession, !(await session.hasCompleted) {
            try? await session.terminate()
        }
        terminalSession = nil
        isBottomTerminalRunning = false
    }

    private func appendTerminalDelta(_ delta: PTYDelta) {
        let chunk = String(decoding: delta.data, as: UTF8.self)
        let prefix = delta.stream == .stderr ? "stderr: " : ""
        if !chunk.isEmpty {
            bottomTerminalText += "\(prefix)\(chunk)"
        }
        if delta.capReached {
            bottomTerminalText += "\n[output cap reached]\n"
        }
    }

    private func finishBottomTerminalSession(result: CodexCommandExecResult) {
        terminalSession = nil
        terminalOutputTask = nil
        terminalCompletionTask = nil
        isBottomTerminalRunning = false
        bottomTerminalStatus = "Exited \(result.exitCode)"
        if bottomTerminalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            bottomTerminalText = "Command finished with exit code \(result.exitCode).\n"
        }
    }
}

enum CodexPinnedThreadStorage {
    private static let key = "CodexChatExample.pinnedThreadIDs"

    static func load() -> [String] {
        let ids = UserDefaults.standard.stringArray(forKey: key) ?? []
        return deduped(ids)
    }

    static func save(_ ids: [String]) {
        UserDefaults.standard.set(deduped(ids), forKey: key)
    }

    private static func deduped(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for id in ids where !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if seen.insert(id).inserted {
                result.append(id)
            }
        }
        return result
    }
}
