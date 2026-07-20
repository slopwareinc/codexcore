import SwiftUI
import AppKit
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
final class CodexCoreAppModel {
    typealias ConnectionState = CodexConnectionState
    typealias Activity = CodexActivity

    var workspacePath = defaultWorkspacePath()
    var apiKey = ""
    var appearanceSettings: CodexAppearanceSettings = .official {
        didSet {
            CodexAppearanceSettingsStorage.saveAppearanceSettings(appearanceSettings, to: preferenceStore)
        }
    }
    var gitSettings: CodexGitSettings = .defaults {
        didSet {
            CodexGitSettingsStorage.saveGitSettings(gitSettings, to: preferenceStore)
        }
    }
    var newThreadHistoryMode: CodexNewThreadHistoryMode = .defaultForPinnedRelease {
        didSet {
            CodexNewThreadHistoryModeStorage.save(newThreadHistoryMode, to: preferenceStore)
        }
    }
    var sidebarFontSize: Double = CodexSidebarFontSizeStorage.defaultFontSize {
        didSet {
            let clamped = CodexSidebarFontSizeStorage.clamped(sidebarFontSize)
            if sidebarFontSize != clamped {
                sidebarFontSize = clamped
                return
            }
            CodexSidebarFontSizeStorage.saveSidebarFontSize(clamped, to: preferenceStore)
        }
    }
    var theme: CodexAgentTheme {
        var theme = appearanceSettings.agentTheme(uiFontSize: appearanceSettings.uiFontSize, reduceMotion: appearanceSettings.reduceMotion)
        theme.fonts.sidebar = .official(baseTextSize: sidebarFontSize)
        return theme
    }
    private(set) var gitBranch: String?
    private(set) var accountRateLimitsSnapshot: CodexSchemaRateLimitSnapshot?
    private(set) var accountMenuSummary = CodexAccountMenuSummary(displayName: "Codex", detail: "Available")
    private(set) var environmentInfoState: CodexEnvironmentInfoState = .unavailable

    private var codex: Codex?
    var authSession = CodexAuthSession()
    private(set) var currentThreadLease: CodexThreadLease?
    private(set) var selectedThreadID: String?
    private(set) var activeTurnLease: CodexTurnLease?
    private var activeSideChatThreadLease: CodexThreadLease?
    private var activeSideChatTurnLease: CodexTurnLease?
    private var currentThreadObservationTask: Task<Void, Never>?
    private var currentThreadObservationGeneration: UInt64 = 0
    private var threadIndexObservationTask: Task<Void, Never>?
    private var threadIndexObservationGeneration: UInt64 = 0
    private var accountObservationTask: Task<Void, Never>?
    private var accountObservationGeneration: UInt64 = 0
    private var accountPreferredDisplayName: String?
    private var skillsChangedObservationTask: Task<Void, Never>?
    private var skillsChangedObservationGeneration: UInt64 = 0
    private var activeTurnCompletionTask: Task<Void, Never>?
    private var sideChatTurnCompletionTask: Task<Void, Never>?
    private(set) var selectedThreadSessionSnapshot: CodexSessionStateSnapshot?
    private(set) var canonicalThreadIndexSnapshot: CanonicalThreadIndexSnapshot?
    private(set) var canonicalThreadStatusEntries: [String: CodexThreadStatusEntry] = [:]
    private var lastSeenAttentionRevisionByThreadID: [ThreadID: StateRevision] = [:]
    private var hasSeededThreadIndex = false
    private(set) var goalPursuitEnabled = false
    private var loginTask: Task<Void, Never>?
    var threadListSession = CodexThreadListSession(currentWorkspacePath: defaultWorkspacePath())
    var sidebarNavigationSession = CodexSidebarNavigationSession(currentWorkspacePath: defaultWorkspacePath())
    var pinnedThreadIDs: [String]
    private var hasStoredExpandedProjectState: Bool
    var configurationSession = CodexChatConfigurationSession()
    var composerSession = CodexComposerStateSession()
    var activityLog = CodexActivityLogSession()
    var structuredPanelDismissalState = CodexStructuredPanelDismissalState()
    let runtimeSession = CodexChatRuntimeSession()
    let promptRuntime = CodexPromptRuntimeSession()
    private let mentionSearchSession = CodexMentionSearchSession()
    var modelIDByThread: [String: String]
    var lastManualModelID: String?
    let workspacePanel = CodexWorkspacePanelStore(capacity: 20)
    private var chatSelectionGeneration = 0
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

    private let clipboardService: any CodexClipboardService
    let preferenceStore: any CodexStringListPreferenceStore
    let codexHome: CodexHome

    init(
        codexHome: CodexHome = .default,
        clipboardService: any CodexClipboardService,
        preferenceStore: any CodexStringListPreferenceStore
    ) {
        self.codexHome = codexHome
        self.clipboardService = clipboardService
        self.preferenceStore = preferenceStore
        self.appearanceSettings = CodexAppearanceSettingsStorage.loadAppearanceSettings(from: preferenceStore)
        self.gitSettings = CodexGitSettingsStorage.loadGitSettings(from: preferenceStore)
        self.newThreadHistoryMode = CodexNewThreadHistoryModeStorage.load(from: preferenceStore)
        self.sidebarFontSize = CodexSidebarFontSizeStorage.loadSidebarFontSize(from: preferenceStore)
        self.pinnedThreadIDs = CodexPinnedThreadStorage.loadPinnedThreadIDs(from: preferenceStore)
        self.modelIDByThread = CodexModelPreferenceStorage.loadThreadModelIDs(from: preferenceStore)
        self.lastManualModelID = CodexModelPreferenceStorage.loadLastModelID(from: preferenceStore)
        let expandedState = CodexExpandedProjectStorage.loadExpandedProjectState(from: preferenceStore)
        self.hasStoredExpandedProjectState = expandedState.hasStoredState
        self.sidebarNavigationSession = CodexSidebarNavigationSession(
            currentWorkspacePath: defaultWorkspacePath(),
            expandedProjectIDs: expandedState.ids
        )
    }

    convenience init() {
        self.init(
            clipboardService: CodexNoopClipboardService(),
            preferenceStore: CodexNoopStringListPreferenceStore()
        )
    }

    func connect() async {
        guard authSession.beginConnecting() else { return }

        await resetSessionState()
        do {
            let config = CodexConfig(
                codexHome: codexHome,
                cwd: workspacePath,
                clientName: "codex_core_app",
                clientTitle: "CodexCore App",
                clientVersion: "1.0.0",
                capabilities: InitializeCapabilities(
                    mcpServerOpenAIFormElicitation: true
                )
            )
            let codex = try await Codex(config: config)
            self.codex = codex
            await runtimeSession.connect(to: codex)
            promptRuntime.connect(to: codex.session) { [weak self] activity in
                self?.appendActivity(.notice, title: activity.title, detail: activity.detail)
            }
            startThreadIndexObservation(session: codex.session)
            await startSkillsChangedObservation(session: codex.session)
            let server = "Codex"
            // Codex construction does not return until initialize + initialized
            // complete, so ready is never exposed during the wire handshake.
            authSession.connectedAfterHandshake(server: server)
            accountMenuSummary = CodexAccountMenuSummary(account: nil, serverName: server)
            accountPreferredDisplayName = CodexAuthTokenProfileReader.displayName(codexHome: codex.codexHome)

            var shouldContinue = true
            do {
                let account = try await codex.perform(CodexRequest.accountRead(.init(refreshToken: false)))
                print("[codextrace] account/read \(CodexAccountDetailLog.json(from: account))")
                accountMenuSummary = CodexAccountMenuSummary(
                    account: account.account,
                    displayName: accountPreferredDisplayName,
                    serverName: server
                )
                let authCheck = authSession.applyAccount(account)
                if let activity = authCheck.activity {
                    appendActivity(activity)
                }
                shouldContinue = authCheck.shouldContinue
            } catch {
                appendActivity(authSession.accountCheckSkipped(message: friendlyError(error)))
            }
            startAccountObservation(session: codex.session)
            guard shouldContinue else { return }

            try await refreshConnectedSession(using: codex)
        } catch {
            appendActivity(authSession.connectionFailed(message: friendlyError(error)))
        }
    }

    func disconnect() async {
        await stopBottomTerminalSession()
        await runtimeSession.disconnect()
        runtimeSession.reset()
        promptRuntime.disconnect()
        cancelThreadIndexObservation()
        cancelAccountObservation()
        cancelSkillsChangedObservation()
        mentionSearchSession.reset()
        loginTask?.cancel()
        loginTask = nil
        cancelCurrentThreadObservation()
        cancelThreadIndexObservation()
        activeTurnCompletionTask?.cancel()
        sideChatTurnCompletionTask?.cancel()
        activeTurnCompletionTask = nil
        sideChatTurnCompletionTask = nil
        activeTurnLease = nil
        activeSideChatTurnLease = nil
        if let lease = activeSideChatThreadLease {
            await lease.close()
        }
        activeSideChatThreadLease = nil
        if let lease = currentThreadLease {
            await lease.close()
        }
        currentThreadLease = nil
        selectedThreadID = nil
        selectedThreadSessionSnapshot = nil
        canonicalThreadIndexSnapshot = nil
        canonicalThreadStatusEntries.removeAll(keepingCapacity: false)
        lastSeenAttentionRevisionByThreadID.removeAll(keepingCapacity: false)
        hasSeededThreadIndex = false
        workspacePanel.removeAll()
        accountRateLimitsSnapshot = nil
        accountPreferredDisplayName = nil
        gitBranch = nil
        environmentInfoState = .unavailable
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
            let params = try CodexJSONValue.dictionary([
                "type": .string("apiKey"),
                "apiKey": .string(key),
            ]).decode(CodexSchemaLoginAccountParams.self)
            let transaction = try await codex.startLogin(params)
            guard case .anonymous(let attempt) = transaction else {
                throw CodexSDKError.invalidResponse(
                    method: CodexAppServerClientMethod.accountLoginStart.rawValue,
                    value: transaction.response.rawValue
                )
            }
            let completion = try await attempt.completion()
            guard completion.success else {
                throw CodexRPCError(
                    code: -32_000,
                    message: completion.error ?? "API key login did not complete",
                    kind: .codexRpc
                )
            }
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
            let params = try CodexJSONValue.dictionary([
                "type": .string("chatgptDeviceCode")
            ]).decode(CodexSchemaLoginAccountParams.self)
            let transaction = try await codex.startLogin(params)
            guard case .identified(let attempt) = transaction,
                  case .dictionary(let value) = attempt.response.rawValue,
                  case .string(let verificationURL)? = value["verificationUrl"],
                  case .string(let userCode)? = value["userCode"]
            else {
                throw CodexSDKError.invalidResponse(
                    method: CodexAppServerClientMethod.accountLoginStart.rawValue,
                    value: transaction.response.rawValue
                )
            }
            appendActivity(authSession.deviceCodeStarted(url: verificationURL, code: userCode))
            loginTask?.cancel()
            loginTask = Task { [weak self] in
                do {
                    let completion = try await attempt.completion()
                    guard completion.success else {
                        await CodexMainActorProjection.run {
                            guard let self else { return }
                            self.appendActivity(self.authSession.deviceCodeEnded(
                                message: completion.error ?? "Device login did not complete"
                            ))
                        }
                        return
                    }
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
        syncComposerThreadID()
        let route = CodexTurnSubmissionSession.consumeDraft(
            composerSession: &composerSession,
            canSendFollowUp: canSendFollowUp,
            isGoalPursuitEnabled: isGoalPursuitEnabled
        )

        switch route {
        case .none:
            return
        case .followUp(let submission):
            await sendFollowUp(submission: submission)
        case .goal(let submission):
            await sendGoalDraft(submission)
        case .turn(let submission):
            await startMainTurn(submission, restoreDraftOnFailure: true)
        }
    }

    /// Handles send while a turn is already running: steer it immediately or
    /// queue the message for the next turn, per `followUpBehavior`.
    private func sendFollowUp(submission: CodexComposerSubmission) async {
        if followUpBehavior == .steer, let activeTurnLease {
            appendActivity(.turn, title: "Steering turn", detail: submission.prompt)
            do {
                _ = try await activeTurnLease.steer(.init(
                    clientUserMessageID: submission.clientID,
                    expectedTurnID: activeTurnLease.key.turnID.rawValue,
                    input: submission.turnInput.map { CodexSchemaUserInput($0.jsonValue) },
                    threadID: activeTurnLease.key.threadID.rawValue
                ))
            } catch {
                appendActivity(CodexTurnSubmissionSession.failSteeredFollowUp(
                    submission: submission,
                    message: friendlyError(error),
                    composerSession: &composerSession
                ))
            }
            return
        }

        composerSession.enqueueFollowUp(submission)
        appendActivity(.turn, title: "Follow-up queued", detail: submission.prompt)
    }

    /// Sends the next queued follow-up as a fresh turn. Called after a turn
    /// finishes; messages were already rendered when they were queued.
    private func flushQueuedFollowUps() {
        guard let submission = composerSession.dequeueQueuedFollowUpSubmission(isSending: isSending) else { return }

        Task { [weak self] in
            guard let self else { return }
            await startMainTurn(submission, restoreDraftOnFailure: false)
        }
    }

    private func startMainTurn(
        _ incomingSubmission: CodexComposerSubmission,
        restoreDraftOnFailure: Bool
    ) async {
        var submission = incomingSubmission
        appendActivity(runtimeSession.beginMainTurnSubmission(submission))
        do {
            let thread = try await ensureThread()
            if submission.threadID == nil {
                submission.threadID = thread.id.rawValue
            }
            let lease = try await thread.startTurn(turnStartParameters(
                threadID: thread.id,
                input: submission.turnInput,
                clientUserMessageID: submission.clientID
            ))
            activeTurnLease = lease
            runtimeSession.startMainTurn(id: lease.key.turnID.rawValue)
            monitorMainTurn(lease)
        } catch {
            if restoreDraftOnFailure {
                composerSession.restore(submission)
            } else {
                composerSession.requeueFollowUp(submission)
            }
            appendActivity(runtimeSession.failMainTurnSubmission(message: friendlyError(error)))
        }
    }

    private func monitorMainTurn(_ lease: CodexTurnLease) {
        activeTurnCompletionTask?.cancel()
        activeTurnCompletionTask = Task { [weak self] in
            do {
                let terminal = try await lease.awaitTerminal()
                guard !Task.isCancelled, let self else { return }
                if activeTurnLease?.key == lease.key {
                    activeTurnLease = nil
                }
                _ = runtimeSession.finishMainTurn(id: lease.key.turnID.rawValue)
                let failed = terminal.turn.status == .failed
                appendActivity(
                    .turn,
                    title: failed ? "Turn failed" : "Turn finished",
                    detail: terminal.turn.error?.message ?? lease.key.turnID.rawValue
                )
                Task { await refreshRecentChats() }
                flushQueuedFollowUps()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                if activeTurnLease?.key == lease.key {
                    activeTurnLease = nil
                }
                _ = runtimeSession.finishMainTurn(id: lease.key.turnID.rawValue)
                appendActivity(.turn, title: "Turn stream ended", detail: friendlyError(error))
            }
        }
    }

    private func sendGoalDraft(_ incomingSubmission: CodexComposerSubmission) async {
        var submission = incomingSubmission
        appendActivity(.turn, title: "Starting goal", detail: submission.prompt)
        do {
            let thread = try await ensureThread()
            if submission.threadID == nil {
                submission.threadID = thread.id.rawValue
            }
            guard let codex else { throw CodexSDKError.runtimeNotFound }
            _ = try await codex.perform(CodexRequest.threadGoalSet(.init(
                objective: CodexFileReferencePromptCodec.encode(
                    files: submission.referencedFiles,
                    request: submission.prompt
                ),
                status: .active,
                threadID: thread.id.rawValue
            )))
            goalPursuitEnabled = true
            appendActivity(.notice, title: "Goal started", detail: submission.prompt)
        } catch {
            composerSession.restore(submission)
            appendActivity(.turn, title: "Goal failed to start", detail: friendlyError(error))
        }
    }

    func setGoalPursuitEnabled(_ enabled: Bool) {
        guard goalPursuitEnabled != enabled else { return }
        goalPursuitEnabled = enabled
        appendActivity(
            .notice,
            title: enabled ? "Goal pursuit enabled" : "Goal pursuit disabled",
            detail: enabled ? "The next message starts a goal." : "Returning to normal turns."
        )
        if !enabled, selectedThreadGoal != nil {
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
            presentFilePicker()
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

    func addReferencedFileURLs(_ urls: [URL], to threadID: String?) {
        print("[DEBUG-FILE-DROP] model add urls=\(urls.map(\.path)) destinationThread=\(threadID ?? "nil") currentThread=\(currentThreadID ?? "nil")")
        let references = urls.compactMap(CodexReferencedFile.fromDroppedURL)
        print("[DEBUG-FILE-DROP] model validated references=\(references.map { "\($0.displayName):\($0.kind.rawValue)" })")
        guard !references.isEmpty else {
            appendActivity(.notice, title: "Files unavailable", detail: "The selected items could not be referenced.")
            return
        }
        composerSession.addReferencedFiles(references, for: threadID)
        print("[DEBUG-FILE-DROP] model state referencesForDestination=\(composerSession.referencedFiles(for: threadID).map(\.path))")
    }

    private func presentFilePicker() {
        let destinationThreadID = currentThreadID
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor [weak self] in
                self?.addReferencedFileURLs(urls, to: destinationThreadID)
            }
        }
    }

    func clearCurrentGoal() async {
        guard let codex, let threadID = currentThreadID, selectedThreadGoal != nil else {
            goalPursuitEnabled = false
            return
        }
        do {
            _ = try await codex.perform(CodexRequest.threadGoalClear(.init(threadID: threadID)))
            goalPursuitEnabled = false
            appendActivity(.notice, title: "Goal cleared", detail: "Thread goal removed")
        } catch {
            appendActivity(.notice, title: "Goal clear failed", detail: friendlyError(error))
            goalPursuitEnabled = true
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
        await refreshRemoteEnvironment(using: codex)
        try await refreshRateLimits(using: codex)
        refreshGitBranch()
    }

    private func refreshRemoteEnvironment(using codex: Codex) async {
        let provider = CodexAppServerRemoteControlProvider(codex: codex)
        guard let status = try? await provider.readStatus() else {
            environmentInfoState = .unavailable
            return
        }
        mobileRouteSession.apply(status: status)
        await refreshEnvironmentInfo(environmentID: status.environmentID)
    }

    private func refreshRateLimits(using codex: Codex) async throws {
        let response = try await codex.perform(CodexRequest.accountRateLimitsRead())
        accountRateLimitsSnapshot = response.rateLimits
    }

    private func refreshGitBranch() {
        let path = workspacePath
        Task {
            gitBranch = await Self.gitBranch(in: path)
        }
    }

    private func activateThread(_ lease: CodexThreadLease) async {
        let previous = currentThreadLease
        currentThreadLease = lease
        selectedThreadID = lease.id.rawValue
        selectedThreadSessionSnapshot = nil
        goalPursuitEnabled = false
        runtimeSession.selectThread(lease.id.rawValue)
        if let summary = canonicalThreadIndexSnapshot?.summary(for: lease.id) {
            lastSeenAttentionRevisionByThreadID[lease.id] = summary.attentionRevision
        }
        syncComposerThreadID()
        if let codex {
            startCurrentThreadObservation(session: codex.session, threadID: lease.id)
        }
        if let previous, previous !== lease {
            await previous.close()
        }
    }

    private func startCurrentThreadObservation(session: CodexSession, threadID: ThreadID) {
        cancelCurrentThreadObservation()
        currentThreadObservationGeneration &+= 1
        let generation = currentThreadObservationGeneration
        let fields: StateFieldMask = [.thread, .turn, .item, .requests]
        currentThreadObservationTask = Task { [weak self] in
            let observation = await session.observeSessionState(
                scope: .thread(threadID, fields: fields)
            )
            defer {
                Task { await session.cancelObservation(observation.id) }
            }
            guard let self,
                  currentThreadObservationGeneration == generation,
                  selectedThreadID == threadID.rawValue
            else { return }
            applySelectedThreadSnapshot(observation.seed)

            for await _ in observation.signals {
                guard !Task.isCancelled,
                      currentThreadObservationGeneration == generation,
                      selectedThreadID == threadID.rawValue
                else { return }
                let snapshot = await session.sessionStateSnapshot(
                    scope: .thread(threadID, fields: fields)
                )
                applySelectedThreadSnapshot(snapshot)
            }
        }
    }

    private func cancelCurrentThreadObservation() {
        currentThreadObservationGeneration &+= 1
        currentThreadObservationTask?.cancel()
        currentThreadObservationTask = nil
    }

    private func startThreadIndexObservation(session: CodexSession) {
        cancelThreadIndexObservation()
        threadIndexObservationGeneration &+= 1
        let generation = threadIndexObservationGeneration
        threadIndexObservationTask = Task { [weak self] in
            let observation = await session.observeThreadIndex()
            defer {
                Task { await session.cancelObservation(observation.id) }
            }
            guard let self, threadIndexObservationGeneration == generation else { return }
            applyThreadIndexSnapshot(observation.seed)
            for await _ in observation.signals {
                guard !Task.isCancelled, threadIndexObservationGeneration == generation else { return }
                applyThreadIndexSnapshot(await session.threadIndexSnapshot())
            }
        }
    }

    private func cancelThreadIndexObservation() {
        threadIndexObservationGeneration &+= 1
        threadIndexObservationTask?.cancel()
        threadIndexObservationTask = nil
    }

    private func startAccountObservation(session: CodexSession) {
        cancelAccountObservation()
        accountObservationGeneration &+= 1
        let generation = accountObservationGeneration
        accountObservationTask = Task { [weak self] in
            let scope = StateObservationScope.global(fields: .account)
            let observation = await session.observeSessionState(scope: scope)
            defer {
                Task { await session.cancelObservation(observation.id) }
            }
            guard let self, accountObservationGeneration == generation else { return }
            applyCanonicalAccountState(observation.seed.canonical.account)
            for await _ in observation.signals {
                guard !Task.isCancelled, accountObservationGeneration == generation else { return }
                let snapshot = await session.sessionStateSnapshot(scope: scope)
                applyCanonicalAccountState(snapshot.canonical.account)
            }
        }
    }

    private func cancelAccountObservation() {
        accountObservationGeneration &+= 1
        accountObservationTask?.cancel()
        accountObservationTask = nil
    }

    private func startSkillsChangedObservation(session: CodexSession) async {
        cancelSkillsChangedObservation()
        skillsChangedObservationGeneration &+= 1
        let generation = skillsChangedObservationGeneration
        do {
            let changes = try await session.observeSkillsChanges()
            skillsChangedObservationTask = Task { [weak self] in
                do {
                    for try await _ in changes {
                        guard !Task.isCancelled,
                              let self,
                              skillsChangedObservationGeneration == generation
                        else { return }
                        await refreshSlashCommands(forceReload: true)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard let self,
                          skillsChangedObservationGeneration == generation
                    else { return }
                    appendActivity(
                        .notice,
                        title: "Skill updates unavailable",
                        detail: friendlyError(error)
                    )
                }
            }
        } catch {
            appendActivity(
                .notice,
                title: "Skill updates unavailable",
                detail: friendlyError(error)
            )
        }
    }

    private func cancelSkillsChangedObservation() {
        skillsChangedObservationGeneration &+= 1
        skillsChangedObservationTask?.cancel()
        skillsChangedObservationTask = nil
    }

    private func applyCanonicalAccountState(_ account: CanonicalAccountState) {
        guard account.lastChangedRevision != .zero
                || account.authMode != nil
                || account.planType != nil
                || !account.rateLimits.isEmpty
                || !account.extensions.isEmpty
        else { return }

        accountMenuSummary = CodexAccountMenuSummary(
            accountState: account,
            displayName: accountPreferredDisplayName,
            serverName: authSession.serverName
        )
        if account.rateLimits.isEmpty {
            accountRateLimitsSnapshot = nil
        } else {
            accountRateLimitsSnapshot = try? CodexJSONValue.dictionary(account.rateLimits)
                .decode(CodexSchemaRateLimitSnapshot.self)
        }
        if let activity = authSession.applyCanonicalAccount(account).activity {
            appendActivity(activity)
        }
    }

    private func applyThreadIndexSnapshot(_ snapshot: CanonicalThreadIndexSnapshot) {
        canonicalThreadIndexSnapshot = snapshot
        if !hasSeededThreadIndex {
            for summary in snapshot.threads {
                lastSeenAttentionRevisionByThreadID[summary.id] = summary.attentionRevision
            }
            hasSeededThreadIndex = true
        }

        var entries: [String: CodexThreadStatusEntry] = [:]
        entries.reserveCapacity(snapshot.threads.count)
        for summary in snapshot.threads {
            let isSelected = summary.id.rawValue == selectedThreadID
            if isSelected {
                lastSeenAttentionRevisionByThreadID[summary.id] = summary.attentionRevision
            }
            let lastSeen = lastSeenAttentionRevisionByThreadID[summary.id] ?? .zero
            let status: CodexThreadLiveStatus
            if summary.status.isActive || summary.latestTurnStatus == .inProgress {
                status = .running
            } else if summary.latestTurnStatus == .failed {
                status = .failed
            } else {
                status = .idle
            }
            entries[summary.id.rawValue] = .init(
                status: status,
                hasUnreadWhileInactive: !isSelected && lastSeen < summary.attentionRevision,
                lastEventAt: Date()
            )
        }
        canonicalThreadStatusEntries = entries
    }

    private func applySelectedThreadSnapshot(_ snapshot: CodexSessionStateSnapshot) {
        guard let threadID = selectedThreadID,
              snapshot.canonical.threads[ThreadID(threadID)] != nil
        else { return }
        let id = ThreadID(threadID)
        let previousGoal = selectedThreadSessionSnapshot?.canonical.threads[id]?.goal
        selectedThreadSessionSnapshot = snapshot
        runtimeSession.applyCanonicalSnapshot(snapshot)

        let thread = snapshot.canonical.threads[id]
        if thread?.goal != nil {
            goalPursuitEnabled = true
        } else if previousGoal != nil {
            goalPursuitEnabled = false
        }
        let turns = snapshot.canonical.turns(in: id)
        let liveStatus: CodexThreadLiveStatus
        if thread?.status.isActive == true || turns.last?.status == .inProgress {
            liveStatus = .running
        } else if turns.last?.status == .failed {
            liveStatus = .failed
        } else {
            liveStatus = .idle
        }
        canonicalThreadStatusEntries[threadID] = CodexThreadStatusEntry(
            status: liveStatus,
            hasUnreadWhileInactive: false,
            lastEventAt: Date()
        )
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
        applyPreferredModel(for: currentThreadID)
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

        if !hasStoredExpandedProjectState {
            sidebarNavigationSession.setExpandedProjects(
                CodexSidebarNavigationSession.defaultExpandedProjectIDs(projects: session.recentProjects)
            )
            saveExpandedSidebarProjects()
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
        await refreshEnvironmentInfo(environmentID: session.state.status.environmentID)
        appendActivity(activity)
    }

    private func refreshEnvironmentInfo(environmentID: String?) async {
        guard let codex, let environmentID = environmentID?.nilIfBlank else {
            environmentInfoState = .unavailable
            return
        }
        environmentInfoState = .loading
        do {
            let info = try await codex.perform(CodexRequest.environmentInfo(.init(
                environmentID: environmentID
            )))
            environmentInfoState = .available(
                cwd: info.cwd.flatMap { value in
                    guard case .string(let cwd) = value.rawValue else { return nil }
                    return cwd
                },
                shellName: info.shell.name,
                shellPath: info.shell.path
            )
        } catch {
            environmentInfoState = .failed(friendlyError(error))
        }
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
            // without enabling live remote control from the app host.
            var session = mobileRouteSession
            let activity = await session.allow(provider: CodexUnsupportedRemoteControlProvider())
            mobileRouteSession = session
            appendActivity(activity)
        }
    }

    func prepareAutomationDraft(_ request: CodexAutomationDraftRequest) async {
        if request.startsNewChat {
            sidebarNavigationSession.startNewChat(workspacePath: workspacePath)
            invalidatePendingChatSelection()
            clearThreadState()
        } else {
            sidebarNavigationSession.selectRoute(.chat)
        }
        composerSession.setDraft(request.prompt, for: currentThreadID)
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
        saveExpandedSidebarProjects()
    }

    func selectSidebarProject(_ path: String) async {
        sidebarNavigationSession.selectProject(path)
        saveExpandedSidebarProjects()
        await switchWorkspace(to: path)
    }

    func startNewChat(inProject path: String) async {
        sidebarNavigationSession.selectProject(path)
        saveExpandedSidebarProjects()
        if CodexProjectSummary.normalizedPath(path) != CodexProjectSummary.normalizedPath(workspacePath) {
            await switchWorkspace(to: path)
        }
        await startNewChat()
    }

    func selectSidebarChat(_ chat: CodexThreadSummary) async {
        sidebarNavigationSession.selectChat(chat.id, workspacePath: chat.workspacePath)
        saveExpandedSidebarProjects()
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
            saveExpandedSidebarProjects()
            return
        }

        workspacePath = normalized
        sidebarNavigationSession.syncCurrentWorkspace(workspacePath, currentThreadID: nil)
        saveExpandedSidebarProjects()
        invalidatePendingChatSelection()
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
        invalidatePendingChatSelection()
        sidebarNavigationSession.startNewChat(workspacePath: workspacePath)
        saveExpandedSidebarProjects()
        clearThreadState()
        applyPreferredModel(for: nil)
        guard codex != nil else { return }
        await refreshRecentChats()
    }

    func resumeChat(id threadID: String) async {
        guard let codex else { return }
        runtimeSession.selectThread(threadID)
        guard selectedThreadID != threadID || currentThreadLease?.isClosed != false else { return }
        applyPreferredModel(for: threadID)
        chatSelectionGeneration += 1
        let selectionGeneration = chatSelectionGeneration
        let trace = CodexPerformanceTrace(label: "chatLoad")
        let totalSpan = trace.begin("chatLoad.total", metadata: ["threadID": threadID])
        var totalOutcome = "success"
        defer {
            totalSpan.end(metadata: ["threadID": threadID, "outcome": totalOutcome])
        }

        let clearSpan = trace.begin("chatLoad.clearThreadState", metadata: ["threadID": threadID])
        clearThreadState(preserveActiveTranscript: true)
        clearSpan.end(metadata: ["threadID": threadID])
        do {
            let resumeSpan = trace.begin("chatLoad.threadResume", metadata: ["threadID": threadID])
            let lease: CodexThreadLease
            do {
                lease = try await codex.resumeThread(threadResumeParameters(threadID: threadID))
                resumeSpan.end(metadata: ["threadID": lease.id.rawValue, "outcome": "success"])
            } catch {
                resumeSpan.end(metadata: ["threadID": threadID, "outcome": "failure", "error": errorType(error)])
                throw error
            }
            guard chatSelectionGeneration == selectionGeneration else {
                totalOutcome = "superseded"
                trace.event("chatLoad.superseded", metadata: ["threadID": threadID])
                await lease.close()
                return
            }
            await activateThread(lease)
            await attachResumedTurnIfNeeded(
                lease,
                selectionGeneration: selectionGeneration,
                trace: trace
            )
            applyPreferredModel(for: threadID)
            syncComposerThreadID()
            let goalResponse = try? await codex.perform(CodexRequest.threadGoalGet(.init(
                threadID: threadID
            )))
            guard chatSelectionGeneration == selectionGeneration else {
                totalOutcome = "superseded"
                trace.event("chatLoad.superseded", metadata: ["threadID": threadID])
                return
            }
            goalPursuitEnabled = goalResponse?.goal != nil

            let sidebarSpan = trace.begin("chatLoad.sidebarSelect", metadata: ["threadID": lease.id.rawValue])
            sidebarNavigationSession.selectChat(lease.id.rawValue, workspacePath: workspacePath)
            sidebarSpan.end(metadata: ["threadID": lease.id.rawValue])
            appendActivity(.notice, title: "Resumed chat", detail: lease.id.rawValue)
            flushQueuedFollowUps()
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
                invalidatePendingChatSelection()
                clearThreadState()
                composerSession.setDraft(draftPrompt, for: currentThreadID)
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
        let shouldClearSelection = chat.id == currentThreadID || sidebarNavigationSession.selectedThreadID == chat.id
        let archiveGeneration: Int?
        if shouldClearSelection {
            invalidatePendingChatSelection()
            archiveGeneration = chatSelectionGeneration
        } else {
            archiveGeneration = nil
        }
        do {
            _ = try await codex.perform(CodexRequest.threadArchive(.init(threadID: chat.id)))
            setThreadPinned(chat.id, pinned: false, announces: false)
            composerSession.discardThreadState(for: chat.id)
            removeChatFromSidebar(chat.id)
            if shouldClearSelection, chatSelectionGeneration == archiveGeneration {
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

    func resolveApprovalPrompt(id: CodexServerRequestKey, approved: Bool) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if let activity = try await promptRuntime.resolveApprovalPrompt(id: id, approved: approved) {
                    appendActivity(.notice, title: activity.title, detail: activity.detail)
                }
            } catch {
                appendActivity(.notice, title: "Approval failed", detail: friendlyError(error))
            }
        }
    }

    func resolveApprovalPrompt(
        id: CodexServerRequestKey,
        decision: CodexCommandApprovalDecision
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if let activity = try await promptRuntime.resolveApprovalPrompt(id: id, decision: decision) {
                    appendActivity(.notice, title: activity.title, detail: activity.detail)
                }
            } catch {
                appendActivity(.notice, title: "Approval failed", detail: friendlyError(error))
            }
        }
    }

    func submitInteractivePrompt(
        id: CodexServerRequestKey,
        answers: [String: String]
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if let activity = try await promptRuntime.submitInteractivePrompt(
                    id: id,
                    answers: answers
                ) {
                    appendActivity(.notice, title: activity.title, detail: activity.detail)
                }
            } catch {
                appendActivity(.notice, title: "Response failed", detail: friendlyError(error))
            }
        }
    }

    func acceptInteractivePrompt(id: CodexServerRequestKey) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if let activity = try await promptRuntime.acceptInteractivePrompt(id: id) {
                    appendActivity(.notice, title: activity.title, detail: activity.detail)
                }
            } catch {
                appendActivity(.notice, title: "Response failed", detail: friendlyError(error))
            }
        }
    }

    func declineInteractivePrompt(id: CodexServerRequestKey) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if let activity = try await promptRuntime.declineInteractivePrompt(id: id) {
                    appendActivity(.notice, title: activity.title, detail: activity.detail)
                }
            } catch {
                appendActivity(.notice, title: "Response failed", detail: friendlyError(error))
            }
        }
    }

    func resumeSearchResult(_ result: CodexThreadSearchResult) async {
        let workspace = result.thread.workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let workspace, !workspace.isEmpty {
            let normalized = CodexProjectSummary.normalizedPath(workspace)
            if normalized != CodexProjectSummary.normalizedPath(workspacePath) {
                workspacePath = normalized
                sidebarNavigationSession.syncCurrentWorkspace(workspacePath, currentThreadID: nil)
                invalidatePendingChatSelection()
                clearThreadState()
                appendActivity(.notice, title: "Switched project", detail: normalized)
            }
        }
        await resumeChat(id: result.thread.id)
    }

    func forkCurrentChat() async {
        guard let codex, let source = currentThreadLease else { return }
        let sourceSelectionGeneration = chatSelectionGeneration
        let sourceID = source.id.rawValue
        do {
            let fork = try await source.fork(threadForkParameters(threadID: sourceID))
            guard chatSelectionGeneration == sourceSelectionGeneration else { return }
            invalidatePendingChatSelection()
            let forkSelectionGeneration = chatSelectionGeneration
            clearThreadState(keepCurrentThread: true)
            await activateThread(fork)
            guard chatSelectionGeneration == forkSelectionGeneration else { return }
            sidebarNavigationSession.selectChat(fork.id.rawValue, workspacePath: workspacePath)
            appendActivity(.notice, title: "Forked chat", detail: sourceID)
            await refreshRecentChats(using: codex)
        } catch {
            appendActivity(.notice, title: "Fork failed", detail: friendlyError(error))
        }
    }

    func archiveCurrentChat() async {
        guard let codex, let archivedID = currentThreadID else { return }
        invalidatePendingChatSelection()
        let archiveGeneration = chatSelectionGeneration
        do {
            _ = try await codex.perform(CodexRequest.threadArchive(.init(threadID: archivedID)))
            setThreadPinned(archivedID, pinned: false, announces: false)
            composerSession.discardThreadState(for: archivedID)
            removeChatFromSidebar(archivedID)
            if chatSelectionGeneration == archiveGeneration {
                clearThreadState()
                sidebarNavigationSession.syncCurrentWorkspace(workspacePath, currentThreadID: nil)
            }
            appendActivity(.notice, title: "Archived chat", detail: archivedID)
            await refreshRecentChats(using: codex)
        } catch {
            appendActivity(.notice, title: "Archive failed", detail: friendlyError(error))
        }
    }

    func renameCurrentChat(to name: String) async {
        guard let codex, let threadID = currentThreadID else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await codex.perform(CodexRequest.threadNameSet(.init(
                name: trimmed,
                threadID: threadID
            )))
            renameChatInSidebar(threadID, title: trimmed)
            appendActivity(.notice, title: "Renamed chat", detail: trimmed)
            await refreshRecentChats()
        } catch {
            appendActivity(.notice, title: "Rename failed", detail: friendlyError(error))
        }
    }

    func compactCurrentChat() async {
        guard let codex, let threadID = currentThreadID else {
            appendActivity(.notice, title: "Compact unavailable", detail: "No active chat to compact")
            return
        }
        do {
            _ = try await codex.perform(CodexRequest.threadCompactStart(.init(threadID: threadID)))
            appendActivity(.notice, title: "Compact started", detail: "App-server is compacting this chat")
        } catch {
            appendActivity(.notice, title: "Compact failed", detail: friendlyError(error))
        }
    }

    @discardableResult
    private func ensureThread() async throws -> CodexThreadLease {
        guard let codex else { throw CodexSDKError.runtimeNotFound }
        if let currentThreadLease, !currentThreadLease.isClosed {
            return currentThreadLease
        }
        let thread = try await codex.startThread(threadStartParameters())
        await activateThread(thread)
        syncComposerThreadID()
        rememberModelSelection(for: thread.id.rawValue)
        workspacePanel.migrateUnassigned(to: thread.id.rawValue)
        appendActivity(.notice, title: "Thread ready", detail: "Workspace session created")
        return thread
    }

    private var selectedCanonicalThread: CanonicalThread? {
        guard let threadID = currentThreadID else { return nil }
        return selectedThreadSessionSnapshot?.canonical.threads[ThreadID(threadID)]
    }

    private var selectedThreadTurns: [CanonicalTurn] {
        guard let threadID = currentThreadID else { return [] }
        return selectedThreadSessionSnapshot?.canonical.turns(in: ThreadID(threadID)) ?? []
    }

    private var selectedThreadGoal: CanonicalThreadGoal? {
        selectedCanonicalThread?.goal
    }

    /// Restores the control capability for a turn that was already running
    /// when this thread was resumed. The canonical snapshot identifies the
    /// exact composite turn; `attachTurn` performs no protocol request and
    /// keeps steer, interrupt, and terminal waiting on the thread lease.
    private func attachResumedTurnIfNeeded(
        _ thread: CodexThreadLease,
        selectionGeneration: Int,
        trace: CodexPerformanceTrace
    ) async {
        do {
            let snapshot = try await thread.snapshot(fields: [
                .turnStructure,
                .turnStatus,
            ])
            guard chatSelectionGeneration == selectionGeneration,
                  currentThreadLease === thread,
                  let turn = snapshot.turns(in: thread.id).last(where: {
                      $0.status == .inProgress
                  })
            else { return }

            let lease = try await thread.attachTurn(turn.key.turnID)
            guard chatSelectionGeneration == selectionGeneration,
                  currentThreadLease === thread
            else { return }
            activeTurnLease = lease
            runtimeSession.startMainTurn(id: lease.key.turnID.rawValue)
            monitorMainTurn(lease)
            trace.event("chatLoad.activeTurnAttached", metadata: [
                "threadID": lease.key.threadID.rawValue,
                "turnID": lease.key.turnID.rawValue,
            ])
        } catch {
            guard chatSelectionGeneration == selectionGeneration,
                  currentThreadLease === thread
            else { return }
            trace.event("chatLoad.activeTurnAttachFailed", metadata: [
                "threadID": thread.id.rawValue,
                "error": errorType(error),
            ])
            appendActivity(
                .notice,
                title: "Active turn controls unavailable",
                detail: friendlyError(error)
            )
        }
    }

    private var protocolApprovalPolicy: CodexSchemaAskForApproval? {
        if case .string(let raw)? = configurationSession.turnParameterOverrides["approvalPolicy"] {
            return CodexSchemaAskForApproval(.string(raw))
        }
        return approvalSelection.approvalMode.settings.approvalPolicy.map {
            CodexSchemaAskForApproval(.string($0.rawValue))
        }
    }

    private var protocolApprovalsReviewer: CodexSchemaApprovalsReviewer? {
        let raw: String?
        if case .string(let override)? = configurationSession.turnParameterOverrides["approvalsReviewer"] {
            raw = override
        } else {
            raw = approvalSelection.approvalMode.settings.approvalsReviewer?.rawValue
        }
        return raw.flatMap(CodexSchemaApprovalsReviewer.init(rawValue:))
    }

    private func threadStartParameters() -> CodexSchemaThreadStartParams {
        CodexSchemaThreadStartParams(
            approvalPolicy: protocolApprovalPolicy,
            approvalsReviewer: protocolApprovalsReviewer,
            cwd: workspacePath,
            historyMode: CodexSchemaThreadHistoryMode(rawValue: newThreadHistoryMode.rawValue),
            model: modelSelection.modelIdentifier,
            sandbox: CodexSchemaSandboxMode(rawValue: approvalSelection.sandbox.threadMode.rawValue)
        )
    }

    private func threadResumeParameters(threadID: String) -> CodexSchemaThreadResumeParams {
        CodexSchemaThreadResumeParams(
            approvalPolicy: protocolApprovalPolicy,
            approvalsReviewer: protocolApprovalsReviewer,
            cwd: workspacePath,
            model: modelSelection.modelIdentifier,
            sandbox: CodexSchemaSandboxMode(rawValue: approvalSelection.sandbox.threadMode.rawValue),
            threadID: threadID
        )
    }

    private func threadForkParameters(
        threadID: String,
        ephemeral: Bool = false
    ) -> CodexSchemaThreadForkParams {
        CodexSchemaThreadForkParams(
            approvalPolicy: protocolApprovalPolicy,
            approvalsReviewer: protocolApprovalsReviewer,
            cwd: workspacePath,
            ephemeral: ephemeral,
            model: modelSelection.modelIdentifier,
            sandbox: CodexSchemaSandboxMode(rawValue: approvalSelection.sandbox.threadMode.rawValue),
            threadID: threadID
        )
    }

    private func turnStartParameters(
        threadID: ThreadID,
        input: [CodexInput],
        clientUserMessageID: String
    ) -> CodexSchemaTurnStartParams {
        let overrides = configurationSession.turnParameterOverrides
        let collaborationMode = overrides["collaborationMode"].flatMap {
            try? $0.decode(CodexSchemaCollaborationMode.self)
        }
        return CodexSchemaTurnStartParams(
            approvalPolicy: protocolApprovalPolicy,
            approvalsReviewer: protocolApprovalsReviewer,
            clientUserMessageID: clientUserMessageID,
            collaborationMode: collaborationMode,
            cwd: workspacePath,
            effort: CodexSchemaReasoningEffort(.string(reasoningSelection.effort.rawValue)),
            input: input.map { CodexSchemaUserInput($0.jsonValue) },
            model: modelSelection.modelIdentifier,
            sandboxPolicy: CodexSchemaSandboxPolicy(approvalSelection.sandbox.turnPolicy),
            threadID: threadID.rawValue
        )
    }

    @discardableResult
    private func ensureSideChatThread() async throws -> CodexThreadLease {
        if let activeSideChatThreadLease, !activeSideChatThreadLease.isClosed {
            return activeSideChatThreadLease
        }
        guard let source = currentThreadLease else { throw CodexSDKError.runtimeNotFound }
        let lease = try await source.fork(
            threadForkParameters(threadID: source.id.rawValue, ephemeral: true)
        )
        activeSideChatThreadLease = lease
        appendActivity(.notice, title: "Side chat ready", detail: "Forked focused branch")
        return lease
    }

    func interrupt() async {
        guard let activeTurnLease else { return }
        do {
            try await activeTurnLease.interrupt()
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
        for activity in runtimeSession.beginSideChatSubmission(prompt: prompt) {
            appendActivity(activity)
        }
        do {
            let thread = try await ensureSideChatThread()
            let lease = try await thread.startTurn(turnStartParameters(
                threadID: thread.id,
                input: [.text(prompt)],
                clientUserMessageID: UUID().uuidString
            ))
            activeSideChatTurnLease = lease
            runtimeSession.startSideChat(id: lease.key.turnID.rawValue, threadID: thread.id.rawValue)
            monitorSideChatTurn(lease)
        } catch {
            appendActivity(runtimeSession.failSideChatSubmission(message: friendlyError(error)))
        }
    }

    func interruptSideChat() async {
        guard let activeSideChatTurnLease else { return }
        do {
            try await activeSideChatTurnLease.interrupt()
            appendActivity(.turn, title: "Side chat interrupt sent", detail: "Stopping the side chat turn")
        } catch {
            appendActivity(.turn, title: "Side chat interrupt failed", detail: friendlyError(error))
        }
    }

    private func monitorSideChatTurn(_ lease: CodexTurnLease) {
        sideChatTurnCompletionTask?.cancel()
        sideChatTurnCompletionTask = Task { [weak self] in
            do {
                _ = try await lease.awaitTerminal()
                guard !Task.isCancelled, let self else { return }
                if activeSideChatTurnLease?.key == lease.key {
                    activeSideChatTurnLease = nil
                }
                if let activity = runtimeSession.finishSideChat(id: lease.key.turnID.rawValue)?.activity {
                    appendActivity(activity)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                if activeSideChatTurnLease?.key == lease.key {
                    activeSideChatTurnLease = nil
                }
                _ = runtimeSession.finishSideChat(id: lease.key.turnID.rawValue)
                appendActivity(.turn, title: "Side chat ended", detail: friendlyError(error))
            }
        }
    }

    func copyChatTranscript() {
        let transcript = CodexChatUtilitySession.transcriptText(transcript: transcriptV2)
        clipboardService.copy(transcript)

        let detail = CodexChatUtilitySession.copiedTranscriptActivityDetail(messageCount: transcriptV2.turns.count)
        appendActivity(.notice, title: "Copied chat", detail: detail)
    }

    func copyText(_ text: String) {
        clipboardService.copy(text)
    }

    func handleSlashCommand(_ command: CodexSlashCommand, presentMCPStatus: (() -> Void)? = nil) {
        syncComposerThreadID()
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

    private func applyFastCommand() {
        let activity = configurationSession.applyFastCommand()
        rememberManualModelSelection(configurationSession.modelSelection)
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
            messageCount: transcriptV2.turns.count,
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
            turnDiff: currentDiff,
            environmentInfo: environmentInfoState
        )
    }

    private var currentTokenUsageSummary: String? {
        guard let usage = selectedThreadTurns.last?.tokenUsage else { return nil }
        return "\(usage.total.totalTokens) tokens"
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
        syncComposerThreadID()
        composerSession.selectMention(result)
        appendActivity(.notice, title: "Mentioned file", detail: result.path)
    }

    private func clearThreadState(
        keepCurrentThread: Bool = false,
        preserveActiveTranscript: Bool = false
    ) {
        if !keepCurrentThread {
            cancelCurrentThreadObservation()
            activeTurnCompletionTask?.cancel()
            sideChatTurnCompletionTask?.cancel()
            activeTurnCompletionTask = nil
            sideChatTurnCompletionTask = nil
            activeTurnLease = nil
            activeSideChatTurnLease = nil
            let current = currentThreadLease
            let sideChat = activeSideChatThreadLease
            currentThreadLease = nil
            activeSideChatThreadLease = nil
            selectedThreadID = nil
            selectedThreadSessionSnapshot = nil
            Task {
                await sideChat?.close()
                await current?.close()
            }
        }
        runtimeSession.resetThreadState(deactivateTranscript: !preserveActiveTranscript)
        syncComposerThreadID()
        composerSession.clearThreadState()
    }

    private func syncComposerThreadID() {
        composerSession.setActiveThreadID(currentThreadID)
    }

    private func resetSessionState() async {
        await stopBottomTerminalSession()
        await runtimeSession.disconnect()
        promptRuntime.disconnect()
        cancelCurrentThreadObservation()
        cancelThreadIndexObservation()
        cancelAccountObservation()
        cancelSkillsChangedObservation()
        mentionSearchSession.reset()
        structuredPanelDismissalState = CodexStructuredPanelDismissalState()
        loginTask?.cancel()
        loginTask = nil
        let previousCodex = codex
        codex = nil
        await previousCodex?.close()
        accountPreferredDisplayName = nil
        authSession.resetAuthentication()
        threadListSession.reset(currentWorkspacePath: workspacePath)
        sidebarNavigationSession.syncCurrentWorkspace(workspacePath, currentThreadID: nil)
        runtimeSession.integrationCatalogSession.reset()
        configurationSession.reset()
        invalidatePendingChatSelection()
        clearThreadState()
    }

    private func invalidatePendingChatSelection() {
        chatSelectionGeneration += 1
    }

    private func setThreadPinned(_ threadID: String, pinned: Bool, announces: Bool = true) {
        if pinned {
            pinnedThreadIDs.removeAll { $0 == threadID }
            pinnedThreadIDs.insert(threadID, at: 0)
        } else {
            pinnedThreadIDs.removeAll { $0 == threadID }
        }
        CodexPinnedThreadStorage.savePinnedThreadIDs(pinnedThreadIDs, to: preferenceStore)
        guard announces else { return }
        appendActivity(
            .notice,
            title: pinned ? "Pinned chat" : "Unpinned chat",
            detail: threadID
        )
    }

    private func saveExpandedSidebarProjects() {
        CodexExpandedProjectStorage.saveExpandedProjectIDs(sidebarNavigationSession.expandedProjectIDs, to: preferenceStore)
        hasStoredExpandedProjectState = true
    }

    private func renameChatInSidebar(_ threadID: String, title: String) {
        var session = threadListSession
        session.renameThread(id: threadID, title: title, currentWorkspacePath: workspacePath)
        threadListSession = session
    }

    private func removeChatFromSidebar(_ threadID: String) {
        workspacePanel.purge(threadID: threadID)
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
            let session = try await codex.session.startCommandExec(.init(
                command: ["echo", "Codex terminal demo"],
                cwd: workspacePath,
                processID: UUID().uuidString,
                tty: false
            ))
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
