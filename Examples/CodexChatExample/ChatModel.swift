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
    var pluginLauncherTarget: CodexComposerPluginLauncher?
    var mobileRouteSession = CodexMobileRouteSession()
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
                    await CodexMainActorProjection.run {
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
                errorMessage: CodexErrorFormat.localizedDescription
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
                await CodexMainActorProjection.run {
                    self.runtimeSession.startMainTurn(handle)
                    self.runtimeSession.consumeMainTurn(handle)
                }
            } catch {
                await CodexMainActorProjection.run {
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
            errorMessage: CodexErrorFormat.localizedDescription
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

    func handleWorktreeHandoffCompletion(_ completion: CodexWorktreeHandoffCompletion) {
        appendActivity(completion.activity)
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
        case .openPluginLauncher(let target):
            pluginLauncherTarget = target
            selectAppRoute(.plugins)
            appendActivity(.notice, title: "Plugin detail", detail: "Opened \(target.title)")
            Task { await refreshPlugins() }
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
            errorMessage: CodexErrorFormat.localizedDescription
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
            errorMessage: CodexErrorFormat.localizedDescription
        )
        configurationSession = session
        appendConfigurationActivity(activity)
    }

    func refreshRecentChats() async {
        guard let codex else { return }
        await refreshRecentChats(using: codex)
    }

    private func refreshRecentChats(using codex: Codex, trace: CodexPerformanceTrace? = nil) async {
        var session = threadListSession
        let activity = await session.refreshRecentChats(
            using: codex,
            currentWorkspacePath: workspacePath,
            trace: trace,
            errorMessage: CodexErrorFormat.localizedDescription
        )
        let applySpan = trace?.begin("threadList.model.apply")
        threadListSession = session
        
        for project in session.recentProjects {
            sidebarNavigationSession.expandProject(project.workspacePath)
        }
        
        if let activity {
            appendActivity(.notice, title: activity.title, detail: activity.detail)
        }
        applySpan?.end(metadata: [
            "currentWorkspaceChatCount": "\(session.recentChats.count)",
            "allChatCount": "\(session.allChats.count)",
            "projectCount": "\(session.recentProjects.count)"
        ])
    }

    func selectAppRoute(_ route: CodexAppRoute) {
        sidebarNavigationSession.selectRoute(route)
        if route == .plugins {
            Task { await refreshPlugins() }
        }
    }

    func performAutomationRouteAction(_ action: CodexAutomationRouteAction) {
        if let request = action.draftRequest {
            Task { await prepareAutomationDraft(request) }
            return
        }
        switch action {
        case .learnMore:
            appendActivity(.notice, title: "Automations", detail: "Automations are created by chatting with Codex; no settings are changed until you send and confirm the flow.")
        case .createViaChat, .template, .addForChat:
            break
        }
    }

    func refreshMobileRemoteControlStatus() async {
        let provider: any CodexRemoteControlProvider
        if let codex {
            provider = CodexAppServerRemoteControlProvider(codex: codex)
        } else {
            provider = CodexUnsupportedRemoteControlProvider()
        }
        var session = mobileRouteSession
        let activity = await session.refreshStatus(provider: provider)
        mobileRouteSession = session
        appendActivity(activity)
    }

    func openMobilePermissionGate() {
        appendActivity(mobileRouteSession.getStarted())
    }

    func cancelMobilePermissionGate() {
        mobileRouteSession.cancelPermissionGate()
    }

    func allowMobileRemoteControlBoundary() {
        Task {
            // The current parity slice exposes the explicit permission boundary
            // without enabling live remote control from the example host.
            var session = mobileRouteSession
            let activity = await session.allow(provider: CodexUnsupportedRemoteControlProvider())
            mobileRouteSession = session
            appendActivity(activity)
        }
    }

    func prepareAutomationDraft(_ request: CodexAutomationDraftRequest) async {
        if request.startsNewChat {
            sidebarNavigationSession.startNewChat(workspacePath: workspacePath)
            clearThreadState()
        } else {
            sidebarNavigationSession.selectRoute(.chat)
        }
        composerSession.draft = request.prompt
        appendActivity(.notice, title: request.activityTitle, detail: request.activityDetail)
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
        let trace = CodexPerformanceTrace(label: "chatLoad")
        let totalSpan = trace.begin("chatLoad.total", metadata: ["threadID": threadID])
        var totalOutcome = "success"
        defer {
            totalSpan.end(metadata: ["threadID": threadID, "outcome": totalOutcome])
        }

        let clearSpan = trace.begin("chatLoad.clearThreadState", metadata: ["threadID": threadID])
        clearThreadState()
        clearSpan.end(metadata: ["threadID": threadID])
        do {
            let resumeSpan = trace.begin("chatLoad.threadResume", metadata: ["threadID": threadID])
            let resumedThread: CodexThread
            do {
                resumedThread = try await threadSession.resumeThread(
                    id: threadID,
                    using: codex,
                    configuration: threadLaunchConfiguration
                )
                resumeSpan.end(metadata: ["threadID": resumedThread.id, "outcome": "success"])
            } catch {
                resumeSpan.end(metadata: ["threadID": threadID, "outcome": "failure", "error": errorType(error)])
                throw error
            }

            await hydrateThreadHistory(for: resumedThread, using: codex, trace: trace)
            await refreshGoal(for: resumedThread, trace: trace)

            let sidebarSpan = trace.begin("chatLoad.sidebarSelect", metadata: ["threadID": threadID])
            sidebarNavigationSession.selectChat(threadID, workspacePath: workspacePath)
            sidebarSpan.end(metadata: ["threadID": threadID])
            appendActivity(.notice, title: "Resumed chat", detail: threadID)
            await refreshRecentChats(using: codex, trace: trace)
        } catch {
            totalOutcome = "failure"
            trace.event("chatLoad.error", metadata: ["threadID": threadID, "error": errorType(error)])
            appendActivity(.notice, title: "Resume failed", detail: friendlyError(error))
        }
    }

    func searchChats(query: String) async {
        var session = threadListSession
        let activity = await session.searchChats(query: query, using: codex, errorMessage: CodexErrorFormat.localizedDescription)
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
            errorMessage: CodexErrorFormat.localizedDescription
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
        let pluginActivity = await session.refreshPlugins(
            using: codex,
            cwds: [workspacePath],
            errorMessage: CodexErrorFormat.localizedDescription
        )
        let skillActivity = await session.refreshSkills(
            using: codex,
            cwds: [workspacePath],
            errorMessage: CodexErrorFormat.localizedDescription
        )
        runtimeSession.integrationCatalogSession = session
        appendIntegrationActivity(pluginActivity)
        appendIntegrationActivity(skillActivity)
    }

    func performPluginCatalogAction(_ action: CodexPluginRouteAction) {
        Task {
            let outcome = await CodexPluginCatalogActionSession.perform(
                action,
                provider: CodexUnsupportedPluginCatalogActionProvider()
            )
            if let draftPrompt = outcome.draftPrompt {
                sidebarNavigationSession.startNewChat(workspacePath: workspacePath)
                clearThreadState()
                composerSession.draft = draftPrompt
            }
            appendIntegrationActivity(outcome.activity)
            if outcome.shouldRefresh {
                await refreshPlugins()
            }
        }
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
        let request = CodexAutomationRouteAction.addForChat(
            threadID: threadID,
            threadTitle: currentChatTitle,
            workspacePath: workspacePath
        ).draftRequest
        guard let request else { return }
        Task { await prepareAutomationDraft(request) }
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

    private func refreshGoal(for thread: CodexThread, trace: CodexPerformanceTrace? = nil) async {
        let span = trace?.begin("chatLoad.goal.refresh", metadata: ["threadID": thread.id])
        do {
            let response = try await thread.goal()
            if let goal = response.goal {
                applyGoal(goal, turnID: nil, shouldAnnounce: false)
                span?.end(metadata: ["threadID": thread.id, "outcome": "success", "goal": "present"])
            } else {
                clearGoalState()
                span?.end(metadata: ["threadID": thread.id, "outcome": "success", "goal": "none"])
            }
        } catch {
            span?.end(metadata: ["threadID": thread.id, "outcome": "failure", "error": errorType(error)])
            appendActivity(.notice, title: "Goal unavailable", detail: friendlyError(error))
        }
    }

    private func hydrateThreadHistory(for thread: CodexThread, using codex: Codex, trace: CodexPerformanceTrace? = nil) async {
        let span = trace?.begin("chatLoad.historyRestore", metadata: ["threadID": thread.id])
        do {
            let result = try await CodexThreadHistorySession.load(threadID: thread.id, using: codex, trace: trace)
            let applySpan = trace?.begin("chatLoad.transcript.apply", metadata: historyMetadata(for: result))
            let activity = runtimeSession.applyHistoryRestore(result)
            appendActivity(activity.kind, title: activity.title, detail: activity.detail)
            let metadata = historyMetadata(for: result).merging(["outcome": "success"]) { _, new in new }
            applySpan?.end(metadata: metadata)
            span?.end(metadata: metadata)
        } catch {
            span?.end(metadata: ["threadID": thread.id, "outcome": "failure", "error": errorType(error)])
            appendActivity(.notice, title: "Transcript unavailable", detail: friendlyError(error))
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
            errorMessage: CodexErrorFormat.localizedDescription
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
        let transcript = CodexChatFormat.transcriptText(messages: messages)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)

        let detail = CodexChatFormat.copiedTranscriptActivityDetail(messageCount: messages.count)
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
        case .openModelSelector:
            appendActivity(.notice, title: "Model", detail: "Use the composer model selector")
        case .openReasoningSelector:
            appendActivity(.notice, title: "Reasoning", detail: "Use the composer reasoning selector")
        case .showCurrentStatus:
            appendActivity(.notice, title: "Status", detail: connectionState.label)
        case .forkCurrentChat:
            Task { await forkCurrentChat() }
        case .compactCurrentChat:
            Task { await compactCurrentChat() }
        case .presentMCPStatus:
            presentMCPStatus?()
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
        CodexErrorFormat.localizedDescription(error)
    }

    private func errorType(_ error: Error) -> String {
        String(describing: type(of: error))
    }

    private func historyMetadata(for result: CodexThreadHistoryRestoreResult) -> [String: String] {
        [
            "threadID": result.hydration.parent.snapshot.id,
            "turnCount": "\(result.hydration.parent.snapshot.turns.count)",
            "itemCount": "\(result.hydration.parent.snapshot.turns.reduce(0) { $0 + $1.items.count })",
            "messageCount": "\(result.messageCount)",
            "restoredChildThreadCount": "\(result.restoredChildThreadCount)",
            "failedChildThreadCount": "\(result.hydration.failedChildThreadIDs.count)"
        ]
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
        return CodexChatFormat.tokenUsageSummary(usage)
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
                await CodexMainActorProjection.run {
                    self.appendActivity(CodexFileChangeUndoSession.successActivity(relativePath: plan.relativePath))
                }
            } catch {
                await CodexMainActorProjection.run {
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
                await CodexMainActorProjection.run {
                    self.appendActivity(.notice, title: "Review started", detail: change.displayPath)
                }
            } catch {
                await CodexMainActorProjection.run {
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
                    await CodexMainActorProjection.run {
                        self?.appendTerminalDelta(delta)
                    }
                }
            }

            terminalCompletionTask = Task { [weak self] in
                do {
                    let result = try await session.wait()
                    await CodexMainActorProjection.run {
                        self?.finishBottomTerminalSession(result: result)
                    }
                } catch {
                    await CodexMainActorProjection.run {
                        self?.isBottomTerminalRunning = false
                        self?.bottomTerminalStatus = "Session failed: \(CodexErrorFormat.localizedDescription(error))"
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
