import SwiftUI
import AppKit
import Observation
import OSLog
import CodexCore
import CodexCoreUI

private enum PluginCatalogToggleRollback {
    case plugin(id: String, enabled: Bool)
    case skill(path: String, enabled: Bool)
    case app(id: String, enabled: Bool)
}

private enum PluginCatalogMutationKey: Hashable {
    case plugin(String)
    case skill(String)
    case app(String)
    case marketplace(String)
}

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

    private static let pluginCatalogLogger = Logger(
        subsystem: "com.slopware.codexcore",
        category: "plugin-catalog"
    )

    // CodexChatRuntimeSession is intentionally not observable. Every catalog
    // write must flow through publishIntegrationCatalogSession so SwiftUI sees it.
    private(set) var integrationCatalogRevision = 0
    private(set) var pendingPluginActionIDs: Set<String> = []
    private(set) var pendingSkillActionIDs: Set<String> = []
    private(set) var pendingAppActionIDs: Set<String> = []
    private(set) var pendingMarketplaceActionIDs: Set<String> = []
    private(set) var marketplaceActionErrors: [String: String] = [:]

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
    // The sidebar has no font-size or font-family setting of its own; it
    // mirrors the app-wide `appearanceSettings.uiFontSize` / `textFontFamily`
    // exactly, threaded through `agentTheme(uiFontSize:reduceMotion:)`.
    var theme: CodexAgentTheme {
        appearanceSettings.agentTheme(uiFontSize: appearanceSettings.uiFontSize, reduceMotion: appearanceSettings.reduceMotion)
    }
    private(set) var gitBranch: String?
    private(set) var accountRateLimitsSnapshot: CodexSchemaRateLimitSnapshot?
    private(set) var accountMenuSummary = CodexAccountMenuSummary(displayName: "Codex", detail: "Available")
    private(set) var environmentInfoState: CodexEnvironmentInfoState = .unavailable
    private(set) var configRequirements: CodexSchemaConfigRequirements?
    private(set) var notificationAuthorizationStatus: CodexNotificationAuthorizationStatus = .unavailable
    private(set) var notificationAuthorizationError: String?

    var codex: Codex?
    var authSession = CodexAuthSession()
    private(set) var currentThreadLease: CodexThreadLease?
    private(set) var selectedThreadID: String? {
        didSet { onVoicePresentationContextChanged?() }
    }
    /// Main-actor seam used by the native Voice overlay. Selection changes are
    /// context changes only; the overlay still observes the same session.
    var onVoicePresentationContextChanged: (@MainActor () -> Void)?
    private(set) var composerFocusRequest = 0
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
    private var connectedSessionBackgroundTasks: [Task<Void, Never>] = []
    private var integrationCatalogRefreshGeneration: UInt64 = 0
    private var activeTurnCompletionTask: Task<Void, Never>?
    private var sideChatTurnCompletionTask: Task<Void, Never>?
    private var pendingSteerSubmissions: [CodexComposerSubmission] = []
    private var pendingSteerSubmissionHead = 0
    private var isProcessingSteerSubmissions = false
    private var processActivityTokens: [String: NSObjectProtocol] = [:]
    private var announcedNotificationPromptIDs: Set<CodexServerRequestKey> = []
    private(set) var selectedThreadSessionSnapshot: CodexSessionStateSnapshot?
    private(set) var canonicalThreadIndexSnapshot: CanonicalThreadIndexSnapshot?
    private(set) var canonicalThreadStatusEntries: [String: CodexThreadStatusEntry] = [:]
    private var unreadState: CodexThreadUnreadState
    private var isApplicationActive = false
    private var isMainWindowKey = false
    private var isConversationViewVisible = false
    private(set) var goalPursuitEnabled = false
    private var loginTask: Task<Void, Never>?
    var threadListSession = CodexThreadListSession(currentWorkspacePath: defaultWorkspacePath())
    var sidebarNavigationSession = CodexSidebarNavigationSession(currentWorkspacePath: defaultWorkspacePath())
    var pinnedThreadIDs: [String]
    var projectlessThreadIDs: Set<String>
    var projectSourceFoldersByPrimaryPath: [String: [String]]
    private var hasStoredExpandedProjectState: Bool
    var configurationSession = CodexChatConfigurationSession()
    var composerSession = CodexComposerStateSession(followUpBehavior: .queue)
    var activityLog = CodexActivityLogSession()
    var structuredPanelDismissalState = CodexStructuredPanelDismissalState()
    let runtimeSession = CodexChatRuntimeSession()
    let promptRuntime = CodexPromptRuntimeSession()
    private let mentionSearchSession = CodexMentionSearchSession()
    var modelPreferenceByThread: [String: CodexModelPreference]
    var lastManualModelPreference: CodexModelPreference?
    let workspacePanel = CodexWorkspacePanelStore(capacity: 20)
    let voiceSession = CodexVoiceChatSession()
    let dictationSession: CodexComposerDictationSession
    var isProjectlessDraft = true
    var projectlessDraftPaths: CodexProjectlessThreadPaths?
    private var chatSelectionGeneration = 0
    var pluginLauncherTarget: CodexComposerPluginLauncher?
    var automationLifecycle: CodexAutomationLifecycle
    var automations: [CodexAutomation] { automationLifecycle.automations }
    private let automationStore: CodexAutomationFileStore
    private let automationNotifications: CodexAutomationNotificationService
    private var automationSchedulerTask: Task<Void, Never>?
    private var automationRunTasks: [String: Task<Void, Never>] = [:]
    private var automationThreadLeases: [String: CodexThreadLease] = [:]
    private var terminalSession: CodexCommandExecSession?
    private var terminalOutputTask: Task<Void, Never>?
    private var terminalCompletionTask: Task<Void, Never>?

    var isBottomTerminalVisible = false
    var bottomTerminalHeight: CGFloat = 280
    var bottomTerminalText = ""
    var bottomTerminalStatus = "Idle"
    var isBottomTerminalRunning = false

    private let clipboardService: any CodexClipboardService
    private let pluginCatalogActionProviderOverride: (any CodexPluginCatalogActionProvider)?
    let preferenceStore: any CodexStringListPreferenceStore
    let codexHome: CodexHome

    var onDockStateChanged: (@MainActor () -> Void)?
    var onNotificationOpen: (@MainActor (String?) -> Void)?

    init(
        codexHome: CodexHome = .default,
        clipboardService: any CodexClipboardService,
        preferenceStore: any CodexStringListPreferenceStore,
        pluginCatalogActionProvider: (any CodexPluginCatalogActionProvider)? = nil
    ) {
        self.codexHome = codexHome
        self.automationStore = CodexAutomationFileStore(
            directoryURL: codexHome.directoryURL.appendingPathComponent("automations", isDirectory: true)
        )
        self.automationNotifications = CodexAutomationNotificationService()
        // Automation files are loaded by the scheduler task after launch. Do
        // not enumerate and parse the user's Codex home during @MainActor init.
        self.automationLifecycle = CodexAutomationLifecycle()
        self.dictationSession = CodexComposerDictationSession()
        self.clipboardService = clipboardService
        self.pluginCatalogActionProviderOverride = pluginCatalogActionProvider
        self.preferenceStore = preferenceStore
        self.appearanceSettings = CodexAppearanceSettingsStorage.loadAppearanceSettings(from: preferenceStore)
        self.gitSettings = CodexGitSettingsStorage.loadGitSettings(from: preferenceStore)
        self.newThreadHistoryMode = CodexNewThreadHistoryModeStorage.load(from: preferenceStore)
        self.pinnedThreadIDs = CodexPinnedThreadStorage.loadPinnedThreadIDs(from: preferenceStore)
        self.unreadState = CodexThreadUnreadState(
            unreadThreadIDs: CodexUnreadThreadStorage.loadUnreadThreadIDs(from: preferenceStore)
        )
        self.projectlessThreadIDs = CodexProjectlessThreadStorage.load(from: preferenceStore)
        self.projectSourceFoldersByPrimaryPath = CodexProjectSourceFoldersStorage.load(from: preferenceStore)
        self.modelPreferenceByThread = CodexModelPreferenceStorage.loadThreadSelections(
            from: preferenceStore
        )
        self.lastManualModelPreference = CodexModelPreferenceStorage.loadLastSelection(
            from: preferenceStore
        )
        let expandedState = CodexExpandedProjectStorage.loadExpandedProjectState(from: preferenceStore)
        let projectOrder = CodexProjectOrderStorage.loadProjectOrder(from: preferenceStore)
        let pinnedProjectIDs = CodexPinnedProjectStorage.loadPinnedProjectIDs(from: preferenceStore)
        let hiddenProjectIDs = CodexHiddenProjectStorage.loadHiddenProjectIDs(from: preferenceStore)
        let projectAliases = CodexProjectAliasStorage.loadProjectAliases(from: preferenceStore)
        self.hasStoredExpandedProjectState = expandedState.hasStoredState
        self.sidebarNavigationSession = CodexSidebarNavigationSession(
            currentWorkspacePath: defaultWorkspacePath(),
            expandedProjectIDs: expandedState.ids,
            projectOrder: projectOrder,
            pinnedProjectIDs: pinnedProjectIDs,
            hiddenProjectIDs: hiddenProjectIDs,
            projectAliases: projectAliases
        )
    }

    convenience init() {
        self.init(
            clipboardService: CodexNoopClipboardService(),
            preferenceStore: CodexNoopStringListPreferenceStore()
        )
    }

    var unreadThreadCount: Int {
        unreadState.unreadThreadIDs.count
    }

    var dockAttentionCount: Int {
        unreadThreadCount + promptRuntime.approvalPrompts.count + promptRuntime.interactivePrompts.count
    }

    var enabledAutomationCount: Int {
        automations.filter(\.isEnabled).count
    }

    var hasInFlightWork: Bool {
        activeTurnLease != nil
            || activeSideChatTurnLease != nil
            || runtimeSession.isSending
            || runtimeSession.isSideChatSending
            || voiceSession.isActive
            || !automationRunTasks.isEmpty
            || enabledAutomationCount > 0
    }

    var terminationConfirmationMessage: String {
        var interrupted: [String] = []
        let activeChatCount = [activeTurnLease, activeSideChatTurnLease]
            .compactMap { $0 }
            .count
            + (runtimeSession.isSending || runtimeSession.isSideChatSending ? 1 : 0)
            + (voiceSession.isActive ? 1 : 0)
        if activeChatCount > 0 {
            interrupted.append(
                activeChatCount == 1 ? "one active chat" : "\(activeChatCount) active chats"
            )
        }
        if enabledAutomationCount > 0 {
            interrupted.append(
                enabledAutomationCount == 1
                    ? "one scheduled task"
                    : "\(enabledAutomationCount) scheduled tasks"
            )
        }
        guard !interrupted.isEmpty else {
            return "Quit CodexCore?"
        }
        let noun = interrupted.joined(separator: " and ")
        return "Quitting will interrupt \(noun). Active chats will stop, and scheduled tasks will not run while CodexCore is closed."
    }

    func connect() async {
        guard authSession.beginConnecting() else { return }

        startAutomationScheduler()
        await resetSessionState()
        do {
            await CodexAppAttestation.shared.prepare()
            let config = CodexConfig(
                codexHome: codexHome,
                cwd: workspacePath,
                clientName: "Codex Desktop",
                clientTitle: "CodexCore App",
                clientVersion: CodexPinnedRuntime.version,
                capabilities: InitializeCapabilities(
                    mcpServerOpenAIFormElicitation: true,
                    requestAttestation: true
                )
            )
            let codex = try await Codex(
                config: config,
                serverRequestHandler: { [weak self] request in
                    guard let self else { return .pending }
                    return await self.handleThreadTaskToolRequest(request)
                }
            )
            self.codex = codex
            await runtimeSession.connect(to: codex)
            promptRuntime.connect(to: codex.session) { [weak self] activity in
                guard let self else { return }
                self.appendActivity(.notice, title: activity.title, detail: activity.detail)
                self.postPromptNotifications(for: activity)
            }
            startThreadIndexObservation(session: codex.session)
            await startSkillsChangedObservation(session: codex.session)
            let server = "Codex"
            // Codex construction does not return until initialize + initialized
            // complete, so ready is never exposed during the wire handshake.
            authSession.connectedAfterHandshake(server: server)
            accountMenuSummary = CodexAccountMenuSummary(account: nil, serverName: server)
            accountPreferredDisplayName = await CodexAuthTokenProfileReader.displayNameAsync(
                codexHome: codex.codexHome
            )

            do {
                configRequirements = try await codex.perform(CodexRequest.configRequirementsRead()).requirements
            } catch {
                configRequirements = nil
                appendActivity(
                    .notice,
                    title: "Managed policy unavailable",
                    detail: friendlyError(error)
                )
            }

            var shouldContinue = true
            do {
                let account = try await codex.perform(CodexRequest.accountRead(.init(refreshToken: false)))
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

            await refreshConnectedSession(using: codex)
        } catch {
            appendActivity(authSession.connectionFailed(message: friendlyError(error)))
        }
    }

    func disconnect() async {
        stopAutomationScheduler()
        dictationSession.abort()
        await voiceSession.stop()
        await stopBottomTerminalSession()
        for task in automationRunTasks.values { task.cancel() }
        automationRunTasks.removeAll()
        for lease in automationThreadLeases.values { await lease.close() }
        automationThreadLeases.removeAll()
        await runtimeSession.disconnect()
        runtimeSession.reset()
        promptRuntime.disconnect()
        cancelThreadIndexObservation()
        cancelAccountObservation()
        cancelSkillsChangedObservation()
        cancelConnectedSessionBackgroundRefreshes()
        mentionSearchSession.reset()
        loginTask?.cancel()
        loginTask = nil
        cancelCurrentThreadObservation()
        cancelThreadIndexObservation()
        activeTurnCompletionTask?.cancel()
        sideChatTurnCompletionTask?.cancel()
        activeTurnCompletionTask = nil
        sideChatTurnCompletionTask = nil
        endAllProcessActivities()
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
        unreadState.resetObservationBaseline()
        workspacePanel.removeAll()
        accountRateLimitsSnapshot = nil
        accountPreferredDisplayName = nil
        gitBranch = nil
        environmentInfoState = .unavailable
        configRequirements = nil
        announcedNotificationPromptIDs.removeAll(keepingCapacity: false)
        let codex = self.codex
        self.codex = nil
        await codex?.close()
        appendActivity(authSession.disconnected())
    }

    func signOut() async {
        guard let codex else {
            await disconnect()
            return
        }

        do {
            _ = try await codex.perform(CodexRequest.accountLogout())
            appendActivity(.notice, title: "Signed out", detail: "The Codex account was disconnected")
            await disconnect()
        } catch {
            appendActivity(.notice, title: "Sign out failed", detail: friendlyError(error))
        }
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
            await refreshConnectedSession(using: codex)
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
        if followUpBehavior == .steer {
            await enqueueSteerSubmission(submission)
            return
        }

        composerSession.enqueueFollowUp(submission)
        appendActivity(.turn, title: "Follow-up queued", detail: submission.prompt)
    }

    func steerQueuedFollowUp(clientID: String) async {
        syncComposerThreadID()
        guard let submission = composerSession.takeQueuedFollowUpSubmission(
                  clientID: clientID,
                  threadID: currentThreadID
              ) else { return }

        await enqueueSteerSubmission(submission)
    }

    /// Serializes steer requests in the same order as the upstream TUI's app
    /// event reducer. This also prevents a terminal notification from draining
    /// the ordinary follow-up queue while a steer race is still being resolved.
    private func enqueueSteerSubmission(_ submission: CodexComposerSubmission) async {
        pendingSteerSubmissions.append(submission)
        guard !isProcessingSteerSubmissions else { return }

        isProcessingSteerSubmissions = true
        defer {
            isProcessingSteerSubmissions = false
            flushQueuedFollowUps()
        }

        while pendingSteerSubmissionHead < pendingSteerSubmissions.count {
            let next = pendingSteerSubmissions[pendingSteerSubmissionHead]
            pendingSteerSubmissionHead += 1
            await processSteerSubmission(next)
        }
        pendingSteerSubmissions.removeAll(keepingCapacity: true)
        pendingSteerSubmissionHead = 0
    }

    private func processSteerSubmission(_ submission: CodexComposerSubmission) async {
        guard let turn = activeTurnLease else {
            await startSubmissionAfterSteerRace(submission, replacing: nil)
            return
        }
        let submissionThreadID = submission.threadID ?? currentThreadID
        guard submissionThreadID == turn.key.threadID.rawValue else {
            requeueFailedSteer(
                submission,
                message: "The selected thread changed before the steer could be sent."
            )
            return
        }

        appendActivity(.turn, title: "Steering turn", detail: submission.prompt)
        do {
            _ = try await turn.steer(.init(
                clientUserMessageID: submission.clientID,
                expectedTurnID: turn.key.turnID.rawValue,
                input: submission.turnInput.map { CodexSchemaUserInput($0.jsonValue) },
                threadID: turn.key.threadID.rawValue
            ))
            restoreAcceptedSteerLeaseIfNeeded(turn)
        } catch {
            switch classifyCodexTurnSteerRace(error) {
            case .noActiveTurn:
                await startSubmissionAfterSteerRace(submission, replacing: turn)

            case .expectedTurnMismatch(let actualTurnID)
                where actualTurnID != turn.key.turnID.rawValue:
                await retrySteerSubmission(
                    submission,
                    replacing: turn,
                    actualTurnID: actualTurnID
                )

            case .expectedTurnMismatch, nil:
                requeueFailedSteer(submission, error: error)
            }
        }
    }

    /// App-server includes its current active turn ID in a mismatch error. The
    /// TUI retries exactly once with that ID, without another read/poll RPC.
    private func retrySteerSubmission(
        _ submission: CodexComposerSubmission,
        replacing staleTurn: CodexTurnLease,
        actualTurnID: String
    ) async {
        guard let thread = currentThreadLease,
              thread.id == staleTurn.key.threadID
        else {
            requeueFailedSteer(
                submission,
                message: "The selected thread changed before the steer retry."
            )
            return
        }

        do {
            let recoveredTurn = try await thread.steerTurn(.init(
                clientUserMessageID: submission.clientID,
                expectedTurnID: actualTurnID,
                input: submission.turnInput.map { CodexSchemaUserInput($0.jsonValue) },
                threadID: thread.id.rawValue
            ))
            activeTurnLease = recoveredTurn
            runtimeSession.startMainTurn(id: recoveredTurn.key.turnID.rawValue)
            monitorMainTurn(recoveredTurn)
        } catch {
            if classifyCodexTurnSteerRace(error) == .noActiveTurn {
                await startSubmissionAfterSteerRace(submission, replacing: staleTurn)
            } else {
                requeueFailedSteer(submission, error: error)
            }
        }
    }

    /// If the active turn completed between local submission and app-server
    /// validation, the TUI falls through directly from failed `turn/steer` to
    /// `turn/start` with the same input. Do the same without waiting for a later
    /// projection tick or losing queue order.
    private func startSubmissionAfterSteerRace(
        _ submission: CodexComposerSubmission,
        replacing staleTurn: CodexTurnLease?
    ) async {
        let submissionThreadID = submission.threadID ?? currentThreadID
        guard submissionThreadID == currentThreadID else {
            requeueFailedSteer(
                submission,
                message: "The selected thread changed before the follow-up could start."
            )
            return
        }

        if let staleTurn, activeTurnLease?.key == staleTurn.key {
            activeTurnLease = nil
            activeTurnCompletionTask?.cancel()
            activeTurnCompletionTask = nil
            _ = runtimeSession.finishMainTurn(id: staleTurn.key.turnID.rawValue)
        }
        await startMainTurn(submission, restoreDraftOnFailure: false)
    }

    private func restoreAcceptedSteerLeaseIfNeeded(_ turn: CodexTurnLease) {
        guard currentThreadID == turn.key.threadID.rawValue,
              activeTurnLease?.key != turn.key
        else { return }
        activeTurnLease = turn
        runtimeSession.startMainTurn(id: turn.key.turnID.rawValue)
        monitorMainTurn(turn)
    }

    private func requeueFailedSteer(_ submission: CodexComposerSubmission, error: Error) {
        requeueFailedSteer(submission, message: friendlyError(error))
    }

    private func requeueFailedSteer(_ submission: CodexComposerSubmission, message: String) {
        composerSession.requeueFollowUp(submission)
        appendActivity(.turn, title: "Steer failed — queued instead", detail: message)
    }

    func removeQueuedFollowUp(clientID: String) {
        syncComposerThreadID()
        _ = composerSession.takeQueuedFollowUpSubmission(
            clientID: clientID,
            threadID: currentThreadID
        )
    }

    func editQueuedFollowUp(clientID: String) {
        syncComposerThreadID()
        guard let submission = composerSession.takeQueuedFollowUpSubmission(
            clientID: clientID,
            threadID: currentThreadID
        ) else { return }
        composerSession.restore(submission)
    }

    /// Sends exactly one queued follow-up as a fresh turn. This mirrors the
    /// upstream TUI queue reducer: dequeue FIFO and synchronously mark the next
    /// turn pending before its asynchronous request starts.
    private func flushQueuedFollowUps(afterTurnEnded: Bool = false) {
        syncComposerThreadID()
        let blocksQueueDrain = runtimeSession.isMainTurnPendingOrRunning
            || activeTurnLease != nil
            || isProcessingSteerSubmissions
            || (!afterTurnEnded && runtimeSession.isSending)
        guard let queued = runtimeSession.dequeueQueuedFollowUp(
            composerSession: &composerSession,
            isSending: blocksQueueDrain
        ) else { return }

        appendActivity(queued.activity)

        Task { [weak self] in
            guard let self else { return }
            await startQueuedFollowUp(queued)
        }
    }

    private func startQueuedFollowUp(_ queued: CodexQueuedFollowUpSubmission) async {
        var submission = queued.submission
        do {
            let thread = try await ensureThread()
            if submission.threadID == nil {
                submission.threadID = thread.id.rawValue
            }
            let permissionConfiguration =
                approvalSelection.permissionProfileWireConfiguration
            let lease = try await thread.startTurn(turnStartParameters(
                threadID: thread.id,
                input: submission.turnInput,
                clientUserMessageID: submission.clientID,
                permissionConfiguration: permissionConfiguration
            ))
            configurationSession.markPermissionProfileActive(
                permissionConfiguration
            )
            activeTurnLease = lease
            runtimeSession.startMainTurn(id: lease.key.turnID.rawValue)
            monitorMainTurn(lease)
        } catch {
            appendActivity(runtimeSession.failQueuedFollowUp(
                queued,
                message: friendlyError(error),
                composerSession: &composerSession
            ))
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
            let permissionConfiguration =
                approvalSelection.permissionProfileWireConfiguration
            let lease = try await thread.startTurn(turnStartParameters(
                threadID: thread.id,
                input: submission.turnInput,
                clientUserMessageID: submission.clientID,
                permissionConfiguration: permissionConfiguration
            ))
            configurationSession.markPermissionProfileActive(
                permissionConfiguration
            )
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
        let activityKey = "turn.\(lease.key.threadID.rawValue).\(lease.key.turnID.rawValue)"
        beginProcessActivity(
            key: activityKey,
            reason: "Running Codex turn in \(lease.key.threadID.rawValue)"
        )
        activeTurnCompletionTask = Task { [weak self] in
            guard let self else { return }
            defer { endProcessActivity(key: activityKey) }
            do {
                let terminal = try await lease.awaitTerminal()
                guard !Task.isCancelled else { return }
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
                automationNotifications.postTurnCompletion(
                    threadID: lease.key.threadID.rawValue,
                    title: currentChatTitle,
                    failure: failed ? terminal.turn.error?.message ?? "The turn failed" : nil
                )
                notifyDockStateChanged()
                Task { await refreshRecentChats() }
                flushQueuedFollowUps(afterTurnEnded: true)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                if activeTurnLease?.key == lease.key {
                    activeTurnLease = nil
                }
                _ = runtimeSession.finishMainTurn(id: lease.key.turnID.rawValue)
                let message = friendlyError(error)
                appendActivity(.turn, title: "Turn stream ended", detail: message)
                automationNotifications.postTurnCompletion(
                    threadID: lease.key.threadID.rawValue,
                    title: currentChatTitle,
                    failure: message
                )
                notifyDockStateChanged()
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
        if enabled, isPlanModeEnabled {
            configurationSession.setPlanModeEnabled(false)
        }
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
        guard completion.resultCard != nil else { return }
        Task { await switchWorkspace(to: completion.environment.workspacePath) }
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
        case .openFilesAndChats:
            selectAppRoute(.search)
        }
    }

    func addReferencedFileURLs(_ urls: [URL], to threadID: String?) {
        let references = urls.compactMap(CodexReferencedFile.fromDroppedURL)
        guard !references.isEmpty else {
            appendActivity(.notice, title: "Files unavailable", detail: "The selected items could not be referenced.")
            return
        }
        composerSession.addReferencedFiles(references, for: threadID)
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
        guard let codex else { return }
        await refreshConnectedSession(using: codex)
    }

    /// Hydrates the sidebar before starting inventories that are not required
    /// to navigate the app. In particular, a slow `app/list` must never hold
    /// project discovery behind the plugin catalog.
    func refreshConnectedSession(using codex: Codex) async {
        await refreshRecentChats(using: codex)
        startConnectedSessionBackgroundRefresh(using: codex)
        refreshGitBranch()
    }

    private func startConnectedSessionBackgroundRefresh(using codex: Codex) {
        cancelConnectedSessionBackgroundRefreshes()
        connectedSessionBackgroundTasks = [
            Task { [weak self] in await self?.refreshStartupCatalogs(using: codex) },
            Task { [weak self] in await self?.refreshPlugins() },
            Task { [weak self] in await self?.refreshRemoteEnvironment(using: codex) },
            Task { [weak self] in await self?.refreshRateLimitsInBackground(using: codex) },
        ]
    }

    private func cancelConnectedSessionBackgroundRefreshes() {
        connectedSessionBackgroundTasks.forEach { $0.cancel() }
        connectedSessionBackgroundTasks.removeAll(keepingCapacity: true)
    }

    private func refreshRemoteEnvironment(using codex: Codex) async {
        guard let status = try? await codex.perform(CodexRequest.remoteControlStatusRead()) else {
            guard !Task.isCancelled, self.codex === codex else { return }
            environmentInfoState = .unavailable
            return
        }
        guard !Task.isCancelled, self.codex === codex else { return }
        await refreshEnvironmentInfo(environmentID: status.environmentID)
    }

    private func refreshRateLimitsInBackground(using codex: Codex) async {
        do {
            try await refreshRateLimits(using: codex)
        } catch {
            guard !Task.isCancelled, self.codex === codex else { return }
            appendActivity(.notice, title: "Rate limits unavailable", detail: friendlyError(error))
        }
    }

    private func refreshRateLimits(using codex: Codex) async throws {
        let response = try await codex.perform(CodexRequest.accountRateLimitsRead())
        guard !Task.isCancelled, self.codex === codex else { return }
        accountRateLimitsSnapshot = response.rateLimits
    }

    #if DEBUG
    /// Git branch resolution shells out, so tests set the resolved value
    /// directly instead of standing up a repository.
    func setGitBranchForTesting(_ branch: String?) {
        gitBranch = branch
    }
    #endif

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
        if let permissionConfiguration = lease.permissionConfiguration {
            configurationSession.applyActiveThreadPermissionConfiguration(
                permissionConfiguration
            )
        }
        clearSelectedThreadUnreadIfFocused()
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
        let previousUnreadThreadIDs = unreadState.unreadThreadIDs
        unreadState.apply(snapshot)
        clearSelectedThreadUnreadIfFocused(persists: false)
        if unreadState.unreadThreadIDs != previousUnreadThreadIDs {
            persistUnreadState()
        }
        rebuildCanonicalThreadStatusEntries(from: snapshot)
        notifyDockStateChanged()
    }

    private func rebuildCanonicalThreadStatusEntries(
        from snapshot: CanonicalThreadIndexSnapshot? = nil
    ) {
        guard let snapshot = snapshot ?? canonicalThreadIndexSnapshot else { return }
        var entries: [String: CodexThreadStatusEntry] = [:]
        entries.reserveCapacity(snapshot.threads.count)
        for summary in snapshot.threads {
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
                hasUnreadWhileInactive: unreadState.isUnread(summary.id),
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
            hasUnreadWhileInactive: unreadState.isUnread(id),
            lastEventAt: Date()
        )
        notifyDockStateChanged()
    }

    func setApplicationActive(_ isActive: Bool) {
        isApplicationActive = isActive
        if isActive {
            reloadPersistedUnreadState()
        }
        clearSelectedThreadUnreadIfFocused()
        notifyDockStateChanged()
    }

    func setMainWindowKey(_ isKey: Bool) {
        isMainWindowKey = isKey
        clearSelectedThreadUnreadIfFocused()
        notifyDockStateChanged()
    }

    func setConversationViewVisible(_ isVisible: Bool) {
        isConversationViewVisible = isVisible
        onVoicePresentationContextChanged?()
        clearSelectedThreadUnreadIfFocused()
    }

    private var isSelectedConversationFocused: Bool {
        isApplicationActive && isMainWindowKey && isConversationViewVisible
    }

    private func reloadPersistedUnreadState() {
        let persisted = CodexUnreadThreadStorage.loadUnreadThreadIDs(from: preferenceStore)
        guard unreadState.replaceUnreadThreadIDs(persisted) else { return }
        rebuildCanonicalThreadStatusEntries()
    }

    private func clearSelectedThreadUnreadIfFocused(persists: Bool = true) {
        let threadID = selectedThreadID.map { ThreadID($0) }
        guard unreadState.markReadIfFocused(
            threadID,
            isConversationFocused: isSelectedConversationFocused
        ) else { return }
        if persists {
            persistUnreadState()
        }
        rebuildCanonicalThreadStatusEntries()
    }

    private func markThreadReadIfFocused(_ threadID: ThreadID) {
        guard isSelectedConversationFocused,
              unreadState.setUnread(false, for: threadID)
        else { return }
        persistUnreadState()
        rebuildCanonicalThreadStatusEntries()
        notifyDockStateChanged()
    }

    private func persistUnreadState() {
        CodexUnreadThreadStorage.saveUnreadThreadIDs(
            unreadState.unreadThreadIDs,
            to: preferenceStore
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
            cwds: workspaceRoots,
            errorMessage: CodexErrorFormat.localizedDescription
        )
        guard !Task.isCancelled, self.codex === codex else { return }
        configurationSession = session
        applyPreferredModel(for: currentThreadID)
        appendConfigurationActivities(activities)
    }

    private func refreshSlashCommands(using codex: Codex, forceReload: Bool = false) async {
        var session = configurationSession
        let activity = await session.refreshSlashCommands(
            using: codex,
            cwds: workspaceRoots,
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

    private func refreshRecentChats(using codex: Codex) async {
        var session = threadListSession
        let activity = await session.refreshRecentChats(
            using: codex,
            currentWorkspacePath: workspacePath,
            errorMessage: CodexErrorFormat.localizedDescription
        )
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
    }

    func selectAppRoute(_ route: CodexAppRoute) {
        sidebarNavigationSession.selectRoute(route)
        if route == .plugins {
            requestPluginRefresh()
        } else if route == .automations {
            Task { await reconcileDueAutomations() }
        }
    }

    func requestPluginRefresh() {
        let state = runtimeSession.integrationCatalogSession
        guard !state.isLoadingPlugins, !state.isLoadingApps, !state.isLoadingSkills, !state.isLoadingMCPServers else { return }
        var loadingState = state
        loadingState.beginMCPRefresh()
        loadingState.beginPluginRefresh()
        loadingState.beginAppRefresh()
        loadingState.beginSkillRefresh()
        publishIntegrationCatalogSession(loadingState)
        Task { await refreshPlugins() }
    }

    func requestPluginRead(_ plugin: CodexPluginSummary) {
        let state = runtimeSession.integrationCatalogSession
        guard state.pluginReadDetails[plugin.id] == nil,
              !state.loadingPluginReadIDs.contains(plugin.id) else { return }
        var loadingState = state
        loadingState.beginPluginRead(id: plugin.id)
        publishIntegrationCatalogSession(loadingState)
        let catalogGeneration = integrationCatalogRefreshGeneration
        Task { await refreshPluginRead(plugin, catalogGeneration: catalogGeneration) }
    }

    private func refreshPluginRead(_ plugin: CodexPluginSummary, catalogGeneration: UInt64) async {
        guard let codex else {
            var state = runtimeSession.integrationCatalogSession
            state.failPluginRead(id: plugin.id, message: "Connect to Codex to load plugin details.")
            publishIntegrationCatalogSession(state)
            return
        }
        do {
            let response = try await codex.pluginRead(CodexPluginProtocolMutation.readParams(for: plugin))
            var state = runtimeSession.integrationCatalogSession
            guard catalogGeneration == integrationCatalogRefreshGeneration else {
                state.cancelPluginRead(id: plugin.id)
                publishIntegrationCatalogSession(state)
                return
            }
            guard state.plugins.contains(where: { $0.id == plugin.id }) else {
                state.cancelPluginRead(id: plugin.id)
                publishIntegrationCatalogSession(state)
                return
            }
            state.applyPluginRead(id: plugin.id, response: response)
            publishIntegrationCatalogSession(state)
        } catch {
            var state = runtimeSession.integrationCatalogSession
            guard catalogGeneration == integrationCatalogRefreshGeneration else {
                state.cancelPluginRead(id: plugin.id)
                publishIntegrationCatalogSession(state)
                return
            }
            state.failPluginRead(id: plugin.id, message: CodexErrorFormat.localizedDescription(error))
            publishIntegrationCatalogSession(state)
        }
    }

    func performAutomationRouteAction(_ action: CodexAutomationRouteAction) {
        if let request = action.draftRequest {
            Task { await prepareAutomationDraft(request) }
            return
        }
        switch action {
        case .save(let automation):
            automationLifecycle.save(automation)
            persistAutomation(id: automation.id, successTitle: "Automation saved")
        case .toggle(let id):
            guard let automation = automationLifecycle.toggle(id: id) else { return }
            persistAutomation(
                id: id,
                successTitle: automation.status == .disabled ? "Automation paused" : "Automation enabled"
            )
        case .delete(let id):
            automationRunTasks[id]?.cancel()
            automationRunTasks[id] = nil
            automationLifecycle.delete(id: id)
            do {
                try automationStore.delete(id: id)
                automationNotifications.removePendingRequests(forAutomationID: id)
                appendActivity(.notice, title: "Automation deleted", detail: "Existing chats were kept")
            } catch {
                appendActivity(.notice, title: "Automation delete failed", detail: friendlyError(error))
            }
        case .runNow(let id):
            startAutomationRun(id: id)
        case .learnMore:
            appendActivity(.notice, title: "Automations", detail: "Scheduled automations run as independent Codex chats while the app is open. Their definitions and run state are stored locally in your Codex home.")
        case .createViaChat, .template, .addForChat:
            break
        }
    }

    func startAutomationScheduler() {
        guard automationSchedulerTask == nil else { return }
        notificationAuthorizationStatus = automationNotifications.authorizationStatus
        notificationAuthorizationError = automationNotifications.authorizationError
        automationNotifications.onAuthorizationStatusChange = { [weak self] status, error in
            self?.notificationAuthorizationStatus = status
            self?.notificationAuthorizationError = error
        }
        automationNotifications.onAction = { [weak self] action in
            self?.handleNotificationAction(action)
        }
        automationNotifications.requestAuthorization()
        automationSchedulerTask = Task { [weak self] in
            guard let self else { return }
            await self.runAutomationScheduler()
        }
    }

    private func stopAutomationScheduler() {
        automationSchedulerTask?.cancel()
        automationSchedulerTask = nil
    }

    private func runAutomationScheduler() async {
        let loaded: CodexAutomationLoadResult = await automationStore.load()
        guard !Task.isCancelled else { return }
        automationLifecycle = CodexAutomationLifecycle(automations: loaded.automations)

        while !Task.isCancelled {
            await withProcessActivity(
                reason: "Checking scheduled Codex automations"
            ) {
                await reconcileDueAutomations()
            }
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func beginProcessActivity(key: String, reason: String) {
        guard processActivityTokens[key] == nil else { return }
        processActivityTokens[key] = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: reason
        )
    }

    private func endProcessActivity(key: String) {
        guard let activity = processActivityTokens.removeValue(forKey: key) else { return }
        ProcessInfo.processInfo.endActivity(activity)
    }

    private func endAllProcessActivities() {
        let activities = Array(processActivityTokens.values)
        processActivityTokens.removeAll(keepingCapacity: false)
        for activity in activities {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    func withProcessActivity<T>(
        reason: String,
        operation: () async throws -> T
    ) async rethrows -> T {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: reason
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }
        return try await operation()
    }

    private func postPromptNotifications(for activity: CodexPromptStateActivity) {
        let currentPromptIDs = Set(
            promptRuntime.approvalPrompts.map(\.id)
                + promptRuntime.interactivePrompts.map(\.id)
        )
        announcedNotificationPromptIDs.formIntersection(currentPromptIDs)
        switch activity.title {
        case "Approval requested":
            for prompt in promptRuntime.approvalPrompts where announcedNotificationPromptIDs.insert(prompt.id).inserted {
                automationNotifications.postApprovalRequired(
                    promptID: prompt.id.presentationID,
                    title: prompt.title,
                    detail: prompt.detail,
                    threadID: prompt.threadId
                )
            }
        case "Input requested":
            for prompt in promptRuntime.interactivePrompts where announcedNotificationPromptIDs.insert(prompt.id).inserted {
                automationNotifications.postInputRequired(
                    promptID: prompt.id.presentationID,
                    title: prompt.title,
                    detail: prompt.detail,
                    threadID: prompt.threadId
                )
            }
        default:
            break
        }
        notifyDockStateChanged()
    }

    private func handleNotificationAction(_ action: CodexNotificationAction) {
        switch action {
        case .open(let threadID):
            onNotificationOpen?(threadID)
        case .approve(let promptID), .deny(let promptID):
            guard let prompt = promptRuntime.approvalPrompts.first(where: {
                $0.id.presentationID == promptID
            }) else { return }
            onNotificationOpen?(prompt.threadId)
            let approved = if case .approve = action { true } else { false }
            resolveApprovalPrompt(id: prompt.id, approved: approved)
        }
    }

    private func notifyDockStateChanged() {
        onDockStateChanged?()
    }

    private func reconcileDueAutomations(now: Date = Date()) async {
        for automation in automationLifecycle.due(at: now) {
            startAutomationRun(id: automation.id, now: now)
        }
    }

    private func startAutomationRun(id: String, now: Date = Date()) {
        guard automationRunTasks[id] == nil,
              let automation = automationLifecycle.beginRun(id: id, now: now)
        else { return }
        persistAutomation(id: id, announces: false)

        automationRunTasks[id] = Task { [weak self] in
            guard let self else { return }
            await runAutomation(automation)
        }
    }

    private func runAutomation(_ automation: CodexAutomation) async {
        var threadID: String?
        var failure: String?
        defer { automationRunTasks[automation.id] = nil }

        guard let codex else {
            let message = "Connect Codex to run this automation"
            automationLifecycle.finishRun(id: automation.id, threadID: nil, error: message)
            persistAutomation(id: automation.id, announces: false)
            postAutomationNotification(name: automation.name, failure: message)
            appendActivity(.notice, title: "Automation failed", detail: message)
            return
        }

        do {
            try await withProcessActivity(
                reason: "Running automation \(automation.name)"
            ) {
                let thread = try await codex.startThread(threadStartParameters())
                automationThreadLeases[automation.id] = thread
                threadID = thread.id.rawValue
                let permissionConfiguration = approvalSelection.permissionProfileWireConfiguration
                let turn = try await thread.startTurn(turnStartParameters(
                    threadID: thread.id,
                    input: [.text(automation.prompt)],
                    clientUserMessageID: UUID().uuidString,
                    permissionConfiguration: permissionConfiguration
                ))
                let terminal = try await turn.awaitTerminal()
                if terminal.turn.status == .failed {
                    failure = terminal.turn.error?.message ?? "The scheduled turn failed"
                }
            }
        } catch is CancellationError {
            failure = "Run cancelled"
        } catch {
            failure = friendlyError(error)
        }

        if let thread = automationThreadLeases.removeValue(forKey: automation.id) {
            await thread.close()
        }
        automationLifecycle.finishRun(id: automation.id, threadID: threadID, error: failure)
        persistAutomation(id: automation.id, announces: false)
        await refreshRecentChats()
        postAutomationNotification(name: automation.name, failure: failure)
        appendActivity(
            failure == nil ? .turn : .notice,
            title: failure == nil ? "Automation finished" : "Automation failed",
            detail: failure ?? automation.name
        )
    }

    private func persistAutomation(
        id: String,
        successTitle: String? = nil,
        announces: Bool = true
    ) {
        guard let automation = automations.first(where: { $0.id == id }) else { return }
        do {
            try automationStore.save(automation)
            if announces, let successTitle {
                appendActivity(.notice, title: successTitle, detail: automation.schedule.summary)
            }
        } catch {
            appendActivity(.notice, title: "Automation save failed", detail: friendlyError(error))
        }
    }

    private func postAutomationNotification(name: String, failure: String?) {
        automationNotifications.postCompletion(name: name, failure: failure)
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

    func moveSidebarProject(
        _ sourcePath: String,
        relativeTo targetPath: String,
        placement: CodexProjectDropPlacement
    ) {
        guard sidebarNavigationSession.moveProject(
            sourcePath,
            relativeTo: targetPath,
            placement: placement,
            among: recentProjects
        ) else { return }
        saveSidebarProjectOrder()
    }

    func toggleSidebarProjectPin(_ workspacePath: String) {
        _ = sidebarNavigationSession.toggleProjectPin(workspacePath)
        CodexPinnedProjectStorage.savePinnedProjectIDs(
            sidebarNavigationSession.pinnedProjectIDs,
            to: preferenceStore
        )
    }

    func renameSidebarProject(_ workspacePath: String, displayName: String) {
        sidebarNavigationSession.renameProject(workspacePath, displayName: displayName)
        CodexProjectAliasStorage.saveProjectAliases(
            sidebarNavigationSession.projectAliases,
            to: preferenceStore
        )
    }

    func updateSidebarProject(
        _ project: CodexProjectSummary,
        displayName: String,
        sourceFolders: [String]
    ) async {
        let roots = CodexProjectSummary.normalizedSourceFolders(sourceFolders)
        guard let newPrimary = roots.first else { return }
        let oldPrimary = project.workspacePath

        projectSourceFoldersByPrimaryPath = CodexProjectSourceFoldersStorage.updating(
            projectSourceFoldersByPrimaryPath,
            oldPrimary: oldPrimary,
            sourceFolders: roots
        )
        CodexProjectSourceFoldersStorage.save(
            projectSourceFoldersByPrimaryPath,
            to: preferenceStore
        )

        sidebarNavigationSession.replaceProjectPath(oldPrimary, with: newPrimary)
        sidebarNavigationSession.renameProject(newPrimary, displayName: displayName)
        saveExpandedSidebarProjects()
        saveSidebarProjectOrder()
        saveSidebarProjectVisibility()
        CodexPinnedProjectStorage.savePinnedProjectIDs(
            sidebarNavigationSession.pinnedProjectIDs,
            to: preferenceStore
        )
        CodexProjectAliasStorage.saveProjectAliases(
            sidebarNavigationSession.projectAliases,
            to: preferenceStore
        )

        if project.contains(workspacePath: workspacePath) {
            workspacePath = newPrimary
            refreshGitBranch()
            sidebarNavigationSession.syncCurrentWorkspace(
                newPrimary,
                currentThreadID: currentThreadID
            )
        }
        threadListSession.refreshProjects(currentWorkspacePath: workspacePath)
        appendActivity(
            .notice,
            title: "Updated project",
            detail: "\(roots.count) source folder\(roots.count == 1 ? "" : "s")"
        )
        if let codex {
            await refreshSlashCommands(using: codex)
            await refreshRecentChats(using: codex)
        }
    }

    func removeSidebarProject(_ workspacePath: String) {
        sidebarNavigationSession.removeProject(workspacePath)
        saveSidebarProjectVisibility()
        CodexPinnedProjectStorage.savePinnedProjectIDs(
            sidebarNavigationSession.pinnedProjectIDs,
            to: preferenceStore
        )
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
        isProjectlessDraft = false
        projectlessDraftPaths = nil
        invalidatePendingChatSelection()
        sidebarNavigationSession.startNewChat(workspacePath: workspacePath)
        saveExpandedSidebarProjects()
        clearThreadState()
        applyPreferredModel(for: nil)
        guard codex != nil else { return }
        await refreshRecentChats()
    }

    func selectSidebarChat(_ chat: CodexThreadSummary) async {
        markThreadReadIfFocused(ThreadID(chat.id))
        if projectlessThreadIDs.contains(chat.id) {
            isProjectlessDraft = true
            projectlessDraftPaths = CodexProjectlessThreadPaths(resumingCWD: chat.workspacePath)
            sidebarNavigationSession.selectProjectlessChat(chat.id)
            saveExpandedSidebarProjects()
            await resumeChat(id: chat.id)
            return
        }
        isProjectlessDraft = false
        projectlessDraftPaths = nil
        let projectPath = chat.workspacePath.flatMap { chatPath in
            recentProjects.first { $0.contains(workspacePath: chatPath) }?.workspacePath
        } ?? chat.workspacePath
        sidebarNavigationSession.selectChat(chat.id, workspacePath: projectPath)
        saveExpandedSidebarProjects()
        if let path = projectPath,
           CodexProjectSummary.normalizedPath(path) != CodexProjectSummary.normalizedPath(workspacePath) {
            await switchWorkspace(to: path)
        }
        await resumeChat(id: chat.id)
    }

    func switchWorkspace(to path: String) async {
        let normalized = CodexProjectSummary.normalizedPath(path)
        guard !normalized.isEmpty else { return }
        if sidebarNavigationSession.restoreProject(normalized) {
            saveSidebarProjectVisibility()
        }
        guard normalized != CodexProjectSummary.normalizedPath(workspacePath) else {
            sidebarNavigationSession.syncCurrentWorkspace(workspacePath, currentThreadID: currentThreadID)
            saveExpandedSidebarProjects()
            return
        }

        workspacePath = normalized
        refreshGitBranch()
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
        isProjectlessDraft = true
        projectlessDraftPaths = nil
        invalidatePendingChatSelection()
        sidebarNavigationSession.startNewProjectlessChat()
        saveExpandedSidebarProjects()
        clearThreadState()
        applyPreferredModel(for: nil)
        guard codex != nil else { return }
        await refreshRecentChats()
    }

    func startVoiceChat() async {
        dictationSession.abort()
        if voiceSession.isActive {
            await showVoiceChat()
            return
        }
        guard canStartVoiceChatFromCurrentContext else {
            appendActivity(
                .notice,
                title: "Voice unavailable",
                detail: "Start Voice from Home or reopen an existing Voice task."
            )
            return
        }
        guard let codex else {
            appendActivity(.notice, title: "Voice unavailable", detail: "Connect to Codex first.")
            return
        }

        // A normal composer launch may follow a stopped/failed Voice task. If
        // the selected lease is not that task (or has already closed), clear
        // the retained retry identity before allocating a new thread so a
        // later startup error cannot point the overlay at stale Voice state.
        if !voiceSession.isActive,
           (voiceSession.threadID != nil || voiceSession.phase != .inactive),
           voiceSession.threadID != currentThreadID || currentThreadLease?.isClosed != false {
            await voiceSession.resetForNewSession()
        }

        do {
            let visibleLease: CodexThreadLease
            let createdNewVoiceThread: Bool
            if let currentThreadLease, !currentThreadLease.isClosed {
                visibleLease = currentThreadLease
                createdNewVoiceThread = false
            } else {
                invalidatePendingChatSelection()
                clearThreadState()
                applyPreferredModel(for: nil)
                var start = try threadStartParametersForCurrentDraft()
                start.config = Self.realtimeVoiceFeatureConfig
                start.threadSource = CodexSchemaThreadSource(.string("realtime_voice"))
                start.dynamicTools = Self.voiceTaskToolSpecs
                start.multiAgentMode = Self.explicitRequestOnlyMultiAgentMode
                let provenance = CodexModelPreference(
                    model: configurationSession.modelSelection,
                    serviceTier: configurationSession.serviceTierSelection,
                    isServiceTierExplicit:
                        lastManualModelPreference?.isServiceTierExplicit ?? false
                )
                visibleLease = try await codex.startThread(start)
                createdNewVoiceThread = true
                await activateThread(visibleLease)
                hydrateModelPreference(
                    for: visibleLease.id.rawValue,
                    modelID: visibleLease.modelIdentifier,
                    serviceTierID: visibleLease.serviceTier,
                    provenance: provenance
                )
                if isProjectlessDraft {
                    rememberProjectlessThread(visibleLease.id.rawValue)
                    sidebarNavigationSession.selectProjectlessChat(visibleLease.id.rawValue)
                } else {
                    sidebarNavigationSession.selectChat(
                        visibleLease.id.rawValue,
                        workspacePath: workspacePath
                    )
                }
            }

            if createdNewVoiceThread {
                do {
                    _ = try await codex.perform(CodexRequest.threadNameSet(.init(
                        name: "Voice chat",
                        threadID: visibleLease.id.rawValue
                    )))
                    renameChatInSidebar(visibleLease.id.rawValue, title: "Voice chat")
                } catch {
                    appendActivity(
                        .notice,
                        title: "Voice task naming failed",
                        detail: friendlyError(error)
                    )
                }
            }

            try await voiceSession.start(
                codex: codex,
                threadID: visibleLease.id.rawValue
            )
            appendActivity(.notice, title: "Voice chat started", detail: visibleLease.id.rawValue)
            await refreshRecentChats(using: codex)
        } catch {
            voiceSession.markFailed(error)
            appendActivity(.notice, title: "Voice chat failed", detail: friendlyError(error))
        }
    }

    /// Starts Voice on a fresh projectless task. The active-session guard keeps
    /// the native overlay's "new Voice" action idempotent and prevents a second
    /// realtime transport from being created accidentally.
    func startNewVoiceChat() async {
        guard !voiceSession.isActive else {
            await showVoiceChat()
            return
        }
        await voiceSession.resetForNewSession()
        await startNewChat()
        await startVoiceChat()
    }

    /// Retries the existing Voice task, preserving its thread identity and all
    /// transcript/session presentation state owned by the shared model.
    func retryVoiceChat() async {
        guard !voiceSession.isActive, let threadID = voiceSession.threadID else { return }
        if currentThreadID != threadID {
            await showVoiceChat()
        }
        guard let codex else {
            appendActivity(.notice, title: "Voice unavailable", detail: "Connect to Codex first.")
            return
        }
        do {
            try await voiceSession.start(codex: codex, threadID: threadID)
            appendActivity(.notice, title: "Voice chat resumed", detail: threadID)
            await refreshRecentChats(using: codex)
        } catch {
            voiceSession.markFailed(error)
            appendActivity(.notice, title: "Voice chat failed", detail: friendlyError(error))
        }
    }

    func requestComposerFocus() {
        composerFocusRequest &+= 1
    }

    func stopVoiceChat() async {
        await voiceSession.stop()
        appendActivity(.notice, title: "Voice chat ended", detail: "The task remains in your history.")
        await refreshRecentChats()
    }

    func toggleVoiceMute() {
        voiceSession.toggleMute()
    }

    var canStartVoiceChatFromCurrentContext: Bool {
        guard let currentThreadID else {
            return isProjectlessDraft
        }
        return allSidebarChats.first(where: { $0.id == currentThreadID })?
            .threadSource == "realtime_voice"
    }

    func toggleVoiceOutputMute() {
        voiceSession.toggleOutputMute()
    }

    func showVoiceChat() async {
        guard let threadID = voiceSession.threadID else { return }
        if projectlessThreadIDs.contains(threadID) {
            isProjectlessDraft = true
            if let chat = allSidebarChats.first(where: { $0.id == threadID }) {
                projectlessDraftPaths = CodexProjectlessThreadPaths(
                    resumingCWD: chat.workspacePath
                )
            }
            sidebarNavigationSession.selectProjectlessChat(threadID)
            saveExpandedSidebarProjects()
            await resumeChat(id: threadID)
            return
        }
        if let chat = allSidebarChats.first(where: { $0.id == threadID }) {
            await selectSidebarChat(chat)
        } else {
            await resumeChat(id: threadID)
        }
    }

    /// Opens an independent task referenced by transcript provenance.
    /// Subagent links intentionally use the workspace side panel instead.
    func openThreadReference(_ reference: CodexThreadReferenceV2) async {
        if let chat = allSidebarChats.first(where: { $0.id == reference.threadID }) {
            await selectSidebarChat(chat)
        } else {
            await resumeChat(id: reference.threadID)
        }
    }

    func resumeChat(id threadID: String) async {
        guard let codex else { return }
        runtimeSession.selectThread(threadID)
        guard selectedThreadID != threadID || currentThreadLease?.isClosed != false else { return }
        applyPreferredModel(for: threadID)
        chatSelectionGeneration += 1
        let selectionGeneration = chatSelectionGeneration
        clearThreadState(preserveActiveTranscript: true)
        do {
            let lease = try await codex.resumeThread(
                threadResumeParametersForCurrentContext(threadID: threadID)
            )
            guard chatSelectionGeneration == selectionGeneration else {
                await lease.close()
                return
            }
            hydrateModelPreference(
                for: threadID,
                modelID: lease.modelIdentifier,
                serviceTierID: lease.serviceTier
            )
            await activateThread(lease)
            await attachResumedTurnIfNeeded(
                lease,
                selectionGeneration: selectionGeneration
            )
            applyPreferredModel(for: threadID)
            syncComposerThreadID()
            let goalResponse = try? await codex.perform(CodexRequest.threadGoalGet(.init(
                threadID: threadID
            )))
            guard chatSelectionGeneration == selectionGeneration else {
                return
            }
            goalPursuitEnabled = goalResponse?.goal != nil

            if isProjectlessDraft {
                sidebarNavigationSession.selectProjectlessChat(lease.id.rawValue)
            } else {
                sidebarNavigationSession.selectChat(
                    lease.id.rawValue,
                    workspacePath: workspacePath
                )
            }
            appendActivity(.notice, title: "Resumed chat", detail: lease.id.rawValue)
            flushQueuedFollowUps()
        } catch {
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
            var session = runtimeSession.integrationCatalogSession
            session.requireMCPConnection(message: "Connect to Codex before inspecting MCP servers.")
            publishIntegrationCatalogSession(session)
            return
        }

        var session = runtimeSession.integrationCatalogSession
        let activity = await session.refreshMCPServers(
            using: codex,
            threadID: currentThreadID,
            errorMessage: CodexErrorFormat.localizedDescription
        )
        publishIntegrationCatalogSession(session)
        appendIntegrationActivity(activity)
    }

    func refreshPlugins(forceReloadSkills: Bool = false) async {
        guard let codex else {
            var session = runtimeSession.integrationCatalogSession
            session.requireMCPConnection(message: "Connect to Codex before inspecting MCP servers.")
            session.requirePluginConnection(message: "Connect to Codex before inspecting plugins.")
            publishIntegrationCatalogSession(session)
            return
        }
        integrationCatalogRefreshGeneration &+= 1
        let refreshGeneration = integrationCatalogRefreshGeneration
        let initial = runtimeSession.integrationCatalogSession
        let threadID = currentThreadID
        let cwds = workspaceRoots

        await withTaskGroup(
            of: (CodexIntegrationCatalogInventory, CodexIntegrationCatalogSession, CodexIntegrationCatalogActivity).self
        ) { group in
            group.addTask {
                var session = initial
                let activity = await session.refreshMCPServers(
                    using: codex,
                    threadID: threadID,
                    errorMessage: CodexErrorFormat.localizedDescription
                )
                return (.mcpServers, session, activity)
            }
            group.addTask {
                var session = initial
                let activity = await session.refreshPlugins(
                    using: codex,
                    cwds: cwds,
                    errorMessage: CodexErrorFormat.localizedDescription
                )
                return (.plugins, session, activity)
            }
            group.addTask {
                var session = initial
                let activity = await session.refreshApps(
                    using: codex,
                    threadID: threadID,
                    errorMessage: CodexErrorFormat.localizedDescription
                )
                return (.apps, session, activity)
            }
            group.addTask {
                var session = initial
                let activity = await session.refreshSkills(
                    using: codex,
                    cwds: cwds,
                    forceReload: forceReloadSkills,
                    errorMessage: CodexErrorFormat.localizedDescription
                )
                return (.skills, session, activity)
            }

            for await (inventory, refreshed, activity) in group {
                guard refreshGeneration == integrationCatalogRefreshGeneration else {
                    Self.pluginCatalogLogger.info("discarded stale catalog refresh generation=\(refreshGeneration)")
                    group.cancelAll()
                    return
                }
                var current = runtimeSession.integrationCatalogSession
                current.merge(refreshed, inventory: inventory)
                publishIntegrationCatalogSession(current)
                appendIntegrationActivity(activity)
            }
        }
    }

    /// AGENTS.md layers are read through app-server so remote and sandboxed
    /// hosts resolve the same documents as the agent.
    var agentsDocumentStore: CodexAgentsDocumentStore? {
        codex.map { CodexAgentsDocumentStore(fileSystem: CodexAppServerFileSystem(codex: $0)) }
    }

    var integrationControlPlaneProvider: (any CodexIntegrationControlPlaneProvider)? {
        codex.map(CodexAppServerIntegrationControlPlaneProvider.init(codex:))
    }

    @discardableResult
    func performIntegrationControlPlaneRequest(
        _ request: CodexIntegrationControlPlaneRequest
    ) async -> CodexJSONValue? {
        guard let codex else {
            runtimeSession.integrationControlPlaneSession.requireConnection(
                for: request.surface,
                message: "Connect to Codex before using \(request.surface.rawValue)."
            )
            return nil
        }
        let provider = CodexAppServerIntegrationControlPlaneProvider(codex: codex)
        var session = runtimeSession.integrationControlPlaneSession
        let activity = await session.perform(
            request,
            provider: provider,
            errorMessage: CodexErrorFormat.localizedDescription
        )
        runtimeSession.integrationControlPlaneSession = session
        appendIntegrationActivity(activity)
        return session.response(for: request)
    }

    func performPluginCatalogAction(_ action: CodexPluginRouteAction) {
        let mutationKey = pluginCatalogMutationKey(for: action)
        if let mutationKey, isPluginCatalogMutationPending(mutationKey) {
            Self.pluginCatalogLogger.info("ignored duplicate catalog action while mutation is pending")
            return
        }
        if let mutationKey { setPluginCatalogMutationPending(mutationKey, pending: true) }

        let toggleRollback: PluginCatalogToggleRollback?
        switch action {
        case .setPluginEnabled(let target, let enabled):
            var session = runtimeSession.integrationCatalogSession
            let previous = session.setPluginEnabledOptimistically(id: target.id, enabled: enabled)
            toggleRollback = previous.map { .plugin(id: target.id, enabled: $0) }
            publishIntegrationCatalogSession(session)
            Self.pluginCatalogLogger.info(
                "plugin toggle requested name=\(target.displayName, privacy: .public) enabled=\(enabled) optimisticMatch=\(previous != nil)"
            )
        case .setSkillEnabled(let target, let enabled):
            var session = runtimeSession.integrationCatalogSession
            let previous = session.setSkillEnabledOptimistically(path: target.path, enabled: enabled)
            toggleRollback = previous.map { .skill(path: target.path, enabled: $0) }
            publishIntegrationCatalogSession(session)
            Self.pluginCatalogLogger.info(
                "skill toggle requested name=\(target.displayName, privacy: .public) enabled=\(enabled) optimisticMatch=\(previous != nil) path=\(target.path, privacy: .private)"
            )
        case .installPlugin(let target):
            toggleRollback = nil
            Self.pluginCatalogLogger.info(
                "plugin install requested id=\(target.id, privacy: .public) marketplace=\(target.marketplaceName, privacy: .public)"
            )
        case .uninstallPlugin(let target):
            toggleRollback = nil
            Self.pluginCatalogLogger.info("plugin uninstall requested id=\(target.id, privacy: .public)")
        case .setAppEnabled(let target, let enabled):
            var session = runtimeSession.integrationCatalogSession
            let previous = session.setAppEnabledOptimistically(id: target.id, enabled: enabled)
            toggleRollback = previous.map { .app(id: target.id, enabled: $0) }
            publishIntegrationCatalogSession(session)
            Self.pluginCatalogLogger.info("app execution toggle requested id=\(target.id, privacy: .public) enabled=\(enabled, privacy: .public)")
        case .addMarketplace(let source):
            toggleRollback = nil
            marketplaceActionErrors.removeValue(forKey: source.trimmingCharacters(in: .whitespacesAndNewlines))
            Self.pluginCatalogLogger.info("marketplace add requested source=\(source, privacy: .private)")
        case .upgradeMarketplace(let target):
            toggleRollback = nil
            marketplaceActionErrors.removeValue(forKey: target.name)
            Self.pluginCatalogLogger.info("marketplace upgrade requested name=\(target.name, privacy: .public)")
        case .removeMarketplace(let target):
            toggleRollback = nil
            marketplaceActionErrors.removeValue(forKey: target.name)
            Self.pluginCatalogLogger.info("marketplace remove requested name=\(target.name, privacy: .public)")
        case .tryInChat:
            toggleRollback = nil
        }

        Task {
            let provider: (any CodexPluginCatalogActionProvider)?
            if let pluginCatalogActionProviderOverride {
                provider = pluginCatalogActionProviderOverride
            } else if let codex {
                provider = CodexAppServerPluginCatalogActionProvider(codex: codex)
            } else {
                provider = nil
            }
            guard let provider else {
                Self.pluginCatalogLogger.error("catalog action rejected because app-server is disconnected")
                restoreCatalogToggle(toggleRollback)
                if let mutationKey { setPluginCatalogMutationPending(mutationKey, pending: false) }
                let detail = "Connect to Codex before changing plugins, skills, or marketplaces."
                if case .some(.marketplace(let id)) = mutationKey { marketplaceActionErrors[id] = detail }
                appendIntegrationActivity(.init(
                    title: "Plugin action unavailable",
                    detail: detail
                ))
                return
            }
            let outcome = await performPluginCatalogAction(action, using: provider)
            if outcome.didSucceed {
                Self.pluginCatalogLogger.info(
                    "catalog action succeeded result=\(outcome.activity.title, privacy: .public)"
                )
            } else {
                Self.pluginCatalogLogger.error(
                    "catalog action failed result=\(outcome.activity.title, privacy: .public) detail=\(outcome.activity.detail, privacy: .private)"
                )
            }
            if let draftPrompt = outcome.draftPrompt {
                sidebarNavigationSession.startNewChat(workspacePath: workspacePath)
                invalidatePendingChatSelection()
                clearThreadState()
                composerSession.setDraft(draftPrompt, for: currentThreadID)
            }
            if case .some(.marketplace(let id)) = mutationKey {
                if outcome.didSucceed {
                    marketplaceActionErrors.removeValue(forKey: id)
                } else {
                    marketplaceActionErrors[id] = outcome.activity.detail
                }
            }
            appendIntegrationActivity(outcome.activity)
            // Mutation pending state belongs to the write itself. Catalog refreshes
            // include unrelated transports and must not leave a successful control
            // displaying "Updating" while, for example, MCP inventory is slow.
            if let mutationKey { setPluginCatalogMutationPending(mutationKey, pending: false) }
            if outcome.didSucceed, outcome.shouldRefresh {
                let forceReloadSkills: Bool
                switch action {
                case .installPlugin, .uninstallPlugin, .setPluginEnabled:
                    forceReloadSkills = true
                default:
                    forceReloadSkills = false
                }
                await refreshPlugins(forceReloadSkills: forceReloadSkills)
            } else if !outcome.didSucceed {
                restoreCatalogToggle(toggleRollback)
            }
        }
    }

    private func performPluginCatalogAction(
        _ action: CodexPluginRouteAction,
        using provider: any CodexPluginCatalogActionProvider
    ) async -> CodexPluginActionOutcome {
        switch action {
        case .installPlugin(let target): await provider.installPlugin(target)
        case .uninstallPlugin(let target): await provider.uninstallPlugin(target)
        case .setPluginEnabled(let target, let enabled): await provider.setPluginEnabled(target, enabled: enabled)
        case .setSkillEnabled(let target, let enabled): await provider.setSkillEnabled(target, enabled: enabled)
        case .setAppEnabled(let target, let enabled): await provider.setAppEnabled(target, enabled: enabled)
        case .addMarketplace(let source): await provider.addMarketplace(source: source)
        case .upgradeMarketplace(let target): await provider.upgradeMarketplace(target)
        case .removeMarketplace(let target): await provider.removeMarketplace(target)
        case .tryInChat(let prompt):
            CodexPluginActionOutcome(
                activity: .init(title: "Prepared plugin prompt", detail: prompt),
                draftPrompt: prompt
            )
        }
    }

    func performPluginControlPlaneAction(_ request: CodexIntegrationControlPlaneRequest) {
        Task {
            let response = await performIntegrationControlPlaneRequest(request)
            if case .mcpOAuthLogin = request,
               case .dictionary(let object)? = response,
               case .string(let authorizationURL)? = object["authorizationUrl"],
               let url = URL(string: authorizationURL) {
                NSWorkspace.shared.open(url)
            }

            switch request.permissionBoundary {
            case .pluginMutation, .skillConfigurationWrite, .configurationWrite:
                await refreshPlugins()
            case .externalAuthentication:
                await refreshMCPServers()
            case .externalResourceRead, .externalToolExecution, nil:
                break
            }
        }
    }

    private func pluginCatalogMutationKey(for action: CodexPluginRouteAction) -> PluginCatalogMutationKey? {
        switch action {
        case .installPlugin(let target), .uninstallPlugin(let target), .setPluginEnabled(let target, _):
            return .plugin(target.id)
        case .setSkillEnabled(let target, _):
            return .skill(target.name.contains(":") ? target.name : target.path)
        case .setAppEnabled(let target, _):
            return .app(target.id)
        case .addMarketplace(let source):
            return .marketplace(source.trimmingCharacters(in: .whitespacesAndNewlines))
        case .upgradeMarketplace(let target), .removeMarketplace(let target):
            return .marketplace(target.name)
        case .tryInChat:
            return nil
        }
    }

    private func isPluginCatalogMutationPending(_ key: PluginCatalogMutationKey) -> Bool {
        switch key {
        case .plugin(let id): pendingPluginActionIDs.contains(id)
        case .skill(let id): pendingSkillActionIDs.contains(id)
        case .app(let id): pendingAppActionIDs.contains(id)
        case .marketplace(let id): pendingMarketplaceActionIDs.contains(id)
        }
    }

    private func setPluginCatalogMutationPending(_ key: PluginCatalogMutationKey, pending: Bool) {
        switch key {
        case .plugin(let id):
            if pending { pendingPluginActionIDs.insert(id) } else { pendingPluginActionIDs.remove(id) }
        case .skill(let id):
            if pending { pendingSkillActionIDs.insert(id) } else { pendingSkillActionIDs.remove(id) }
        case .app(let id):
            if pending { pendingAppActionIDs.insert(id) } else { pendingAppActionIDs.remove(id) }
        case .marketplace(let id):
            if pending { pendingMarketplaceActionIDs.insert(id) } else { pendingMarketplaceActionIDs.remove(id) }
        }
    }

    private func restoreCatalogToggle(_ rollback: PluginCatalogToggleRollback?) {
        guard let rollback else { return }
        var session = runtimeSession.integrationCatalogSession
        switch rollback {
        case .plugin(let id, let enabled):
            session.setPluginEnabledOptimistically(id: id, enabled: enabled)
        case .skill(let path, let enabled):
            session.setSkillEnabledOptimistically(path: path, enabled: enabled)
        case .app(let id, let enabled):
            session.setAppEnabledOptimistically(id: id, enabled: enabled)
        }
        publishIntegrationCatalogSession(session)
    }

    private func publishIntegrationCatalogSession(_ session: CodexIntegrationCatalogSession) {
        runtimeSession.integrationCatalogSession = session
        integrationCatalogRevision &+= 1
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
            forgetProjectlessThread(chat.id)
            if shouldClearSelection, chatSelectionGeneration == archiveGeneration {
                clearThreadState()
                if isProjectlessDraft {
                    sidebarNavigationSession.startNewProjectlessChat()
                } else {
                    sidebarNavigationSession.syncCurrentWorkspace(
                        workspacePath,
                        currentThreadID: nil
                    )
                }
            }
            appendActivity(.notice, title: "Archived chat", detail: chat.id)
            await refreshRecentChats(using: codex)
        } catch {
            appendActivity(.notice, title: "Archive failed", detail: friendlyError(error))
        }
    }

    func archiveSidebarProjectChats(_ workspacePath: String) async {
        guard let codex else { return }
        let normalizedPath = CodexProjectSummary.normalizedPath(workspacePath)
        let project = recentProjects.first { $0.workspacePath == normalizedPath }
        let chats = allSidebarChats.filter {
            guard let path = $0.workspacePath else { return false }
            return project?.contains(workspacePath: path)
                ?? (CodexProjectSummary.normalizedPath(path) == normalizedPath)
        }
        guard !chats.isEmpty else {
            appendActivity(.notice, title: "No chats to archive", detail: normalizedPath)
            return
        }

        let selectedID = currentThreadID ?? sidebarNavigationSession.selectedThreadID
        let archiveGeneration = chatSelectionGeneration
        var archivedIDs: Set<String> = []
        var failures = 0
        for chat in chats {
            do {
                _ = try await codex.perform(CodexRequest.threadArchive(.init(threadID: chat.id)))
                archivedIDs.insert(chat.id)
                setThreadPinned(chat.id, pinned: false, announces: false)
                composerSession.discardThreadState(for: chat.id)
                removeChatFromSidebar(chat.id)
            } catch {
                failures += 1
            }
        }

        let currentSelectedID = currentThreadID ?? sidebarNavigationSession.selectedThreadID
        if CodexSidebarArchiveSelectionGuard.shouldClearSelection(
            selectedThreadIDAtStart: selectedID,
            currentSelectedThreadID: currentSelectedID,
            selectionGenerationAtStart: archiveGeneration,
            currentSelectionGeneration: chatSelectionGeneration,
            archivedThreadIDs: archivedIDs
        ) {
            invalidatePendingChatSelection()
            clearThreadState()
            sidebarNavigationSession.syncCurrentWorkspace(workspacePath, currentThreadID: nil)
        }

        if failures == 0 {
            appendActivity(.notice, title: "Archived project chats", detail: "\(archivedIDs.count) chats · \(normalizedPath)")
        } else {
            appendActivity(
                .notice,
                title: "Some chats could not be archived",
                detail: "\(archivedIDs.count) archived, \(failures) failed · \(normalizedPath)"
            )
        }
        await refreshRecentChats(using: codex)
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
                notifyDockStateChanged()
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
                notifyDockStateChanged()
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
                notifyDockStateChanged()
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
                notifyDockStateChanged()
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
                notifyDockStateChanged()
            } catch {
                appendActivity(.notice, title: "Response failed", detail: friendlyError(error))
            }
        }
    }

    func resumeSearchResult(_ result: CodexThreadSearchResult) async {
        markThreadReadIfFocused(ThreadID(result.thread.id))
        if projectlessThreadIDs.contains(result.thread.id) {
            isProjectlessDraft = true
            projectlessDraftPaths = CodexProjectlessThreadPaths(
                resumingCWD: result.thread.workspacePath
            )
            sidebarNavigationSession.selectProjectlessChat(result.thread.id)
            await resumeChat(id: result.thread.id)
            return
        }
        isProjectlessDraft = false
        projectlessDraftPaths = nil
        let workspace = result.thread.workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let workspace, !workspace.isEmpty {
            let normalized = CodexProjectSummary.normalizedPath(workspace)
            if normalized != CodexProjectSummary.normalizedPath(workspacePath) {
                workspacePath = normalized
                refreshGitBranch()
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
            hydrateModelPreference(
                for: fork.id.rawValue,
                modelID: fork.modelIdentifier,
                serviceTierID: fork.serviceTier,
                provenance: modelPreferenceByThread[sourceID]
            )
            invalidatePendingChatSelection()
            let forkSelectionGeneration = chatSelectionGeneration
            clearThreadState(keepCurrentThread: true)
            await activateThread(fork)
            guard chatSelectionGeneration == forkSelectionGeneration else { return }
            applyPreferredModel(for: fork.id.rawValue)
            if isProjectlessDraft {
                rememberProjectlessThread(fork.id.rawValue)
                sidebarNavigationSession.selectProjectlessChat(fork.id.rawValue)
            } else {
                sidebarNavigationSession.selectChat(
                    fork.id.rawValue,
                    workspacePath: workspacePath
                )
            }
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
            forgetProjectlessThread(archivedID)
            if chatSelectionGeneration == archiveGeneration {
                clearThreadState()
                if isProjectlessDraft {
                    sidebarNavigationSession.startNewProjectlessChat()
                } else {
                    sidebarNavigationSession.syncCurrentWorkspace(
                        workspacePath,
                        currentThreadID: nil
                    )
                }
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
        let provenance = CodexModelPreference(
            model: configurationSession.modelSelection,
            serviceTier: configurationSession.serviceTierSelection,
            isServiceTierExplicit:
                lastManualModelPreference?.isServiceTierExplicit ?? false
        )
        let thread = try await codex.startThread(threadStartParametersForCurrentDraft())
        await activateThread(thread)
        hydrateModelPreference(
            for: thread.id.rawValue,
            modelID: thread.modelIdentifier,
            serviceTierID: thread.serviceTier,
            provenance: provenance
        )
        if isProjectlessDraft {
            rememberProjectlessThread(thread.id.rawValue)
            sidebarNavigationSession.selectProjectlessChat(thread.id.rawValue)
        }
        syncComposerThreadID()
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
        selectionGeneration: Int
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
        } catch {
            guard chatSelectionGeneration == selectionGeneration,
                  currentThreadLease === thread
            else { return }
            appendActivity(
                .notice,
                title: "Active turn controls unavailable",
                detail: friendlyError(error)
            )
        }
    }

    func threadStartParameters() -> CodexSchemaThreadStartParams {
        var parameters = configurationSession.wireSelection.applying(to: CodexSchemaThreadStartParams(
            cwd: workspacePath,
            dynamicTools: Self.threadTaskToolSpecs,
            historyMode: CodexSchemaThreadHistoryMode(rawValue: newThreadHistoryMode.rawValue),
            multiAgentMode: Self.explicitRequestOnlyMultiAgentMode,
            runtimeWorkspaceRoots: protocolWorkspaceRoots
        ))
        configurationSession.newThreadApprovalSelection
            .permissionProfileWireConfiguration
            .apply(to: &parameters)
        return parameters
    }

    func threadStartParametersForCurrentDraft() throws -> CodexSchemaThreadStartParams {
        guard isProjectlessDraft else { return threadStartParameters() }
        let paths = try projectlessDraftPaths ?? CodexProjectlessThreadPaths.create()
        projectlessDraftPaths = paths
        var parameters = threadStartParameters()
        parameters.cwd = paths.cwd
        parameters.runtimeWorkspaceRoots = [
            CodexSchemaAbsolutePathBuf(.string(paths.workspaceRoot)),
        ]
        parameters.developerInstructions = paths.developerInstructions
        return parameters
    }

    func threadResumeParametersForCurrentContext(
        threadID: String
    ) -> CodexSchemaThreadResumeParams {
        var parameters = threadResumeParameters(threadID: threadID)
        if isProjectlessDraft, let paths = projectlessDraftPaths {
            parameters.cwd = paths.cwd
            parameters.runtimeWorkspaceRoots = [
                CodexSchemaAbsolutePathBuf(.string(paths.workspaceRoot)),
            ]
        }
        if allSidebarChats.first(where: { $0.id == threadID })?
            .threadSource == "realtime_voice" {
            parameters.config = Self.realtimeVoiceFeatureConfig
        }
        return parameters
    }

    private func rememberProjectlessThread(_ threadID: String) {
        projectlessThreadIDs.insert(threadID)
        CodexProjectlessThreadStorage.save(projectlessThreadIDs, to: preferenceStore)
    }

    private func forgetProjectlessThread(_ threadID: String) {
        guard projectlessThreadIDs.remove(threadID) != nil else { return }
        CodexProjectlessThreadStorage.save(projectlessThreadIDs, to: preferenceStore)
    }

    func threadResumeParameters(threadID: String) -> CodexSchemaThreadResumeParams {
        taskWireSelection(
            for: threadID,
            explicitTierOnly: true
        ).applying(to: CodexSchemaThreadResumeParams(
            cwd: workspacePath,
            runtimeWorkspaceRoots: protocolWorkspaceRoots,
            threadID: threadID
        ))
    }

    func threadForkParameters(
        threadID: String,
        ephemeral: Bool = false
    ) -> CodexSchemaThreadForkParams {
        let cwd = isProjectlessDraft ? projectlessDraftPaths?.cwd ?? workspacePath : workspacePath
        let roots = if isProjectlessDraft, let paths = projectlessDraftPaths {
            [CodexSchemaAbsolutePathBuf(.string(paths.workspaceRoot))]
        } else {
            protocolWorkspaceRoots
        }
        var parameters = taskWireSelection(for: threadID).applying(to: CodexSchemaThreadForkParams(
            cwd: cwd,
            ephemeral: ephemeral,
            runtimeWorkspaceRoots: roots,
            threadID: threadID
        ))
        approvalSelection.permissionProfileWireConfiguration.apply(to: &parameters)
        return parameters
    }

    func turnStartParameters(
        threadID: ThreadID,
        input: [CodexInput],
        clientUserMessageID: String,
        permissionConfiguration: CodexPermissionProfileWireConfiguration
    ) -> CodexSchemaTurnStartParams {
        turnStartParameters(
            threadID: threadID,
            input: input,
            clientUserMessageID: clientUserMessageID,
            viewedThreadID: currentThreadID,
            permissionConfiguration: permissionConfiguration
        )
    }

    func turnStartParameters(
        threadID: ThreadID,
        input: [CodexInput],
        clientUserMessageID: String
    ) -> CodexSchemaTurnStartParams {
        turnStartParameters(
            threadID: threadID,
            input: input,
            clientUserMessageID: clientUserMessageID,
            viewedThreadID: currentThreadID,
            permissionConfiguration: approvalSelection.permissionProfileWireConfiguration
        )
    }

    func turnStartParameters(
        threadID: ThreadID,
        input: [CodexInput],
        clientUserMessageID: String,
        viewedThreadID: String?
    ) -> CodexSchemaTurnStartParams {
        turnStartParameters(
            threadID: threadID,
            input: input,
            clientUserMessageID: clientUserMessageID,
            viewedThreadID: viewedThreadID,
            permissionConfiguration: approvalSelection.permissionProfileWireConfiguration
        )
    }

    private func turnStartParameters(
        threadID: ThreadID,
        input: [CodexInput],
        clientUserMessageID: String,
        viewedThreadID: String?,
        permissionConfiguration: CodexPermissionProfileWireConfiguration
    ) -> CodexSchemaTurnStartParams {
        let collaborationMode = configurationSession.collaborationModeOverride
        let cwd = isProjectlessDraft ? projectlessDraftPaths?.cwd ?? workspacePath : workspacePath
        let roots = if isProjectlessDraft, let paths = projectlessDraftPaths {
            [CodexSchemaAbsolutePathBuf(.string(paths.workspaceRoot))]
        } else {
            protocolWorkspaceRoots
        }
        let wire = taskWireSelection(for: threadID.rawValue)
        let targetWire = if let viewedThreadID,
                            viewedThreadID != threadID.rawValue {
            wire.omittingEffort()
        } else {
            wire
        }
        let effectiveWire = if let collaborationMode,
                               collaborationMode.settings.model != targetWire.modelIdentifier {
            targetWire.omittingModelSpecificOverrides()
        } else {
            targetWire
        }
        var parameters = effectiveWire.applying(to: CodexSchemaTurnStartParams(
            clientUserMessageID: clientUserMessageID,
            collaborationMode: collaborationMode,
            cwd: cwd,
            input: input.map { CodexSchemaUserInput($0.jsonValue) },
            multiAgentMode: Self.explicitRequestOnlyMultiAgentMode,
            runtimeWorkspaceRoots: roots,
            threadID: threadID.rawValue
        ))
        permissionConfiguration.apply(to: &parameters)
        return parameters
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
        hydrateModelPreference(
            for: lease.id.rawValue,
            modelID: lease.modelIdentifier,
            serviceTierID: lease.serviceTier,
            provenance: modelPreferenceByThread[source.id.rawValue]
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
            let permissionConfiguration =
                approvalSelection.permissionProfileWireConfiguration
            let lease = try await thread.startTurn(turnStartParameters(
                threadID: thread.id,
                input: [.text(prompt)],
                clientUserMessageID: UUID().uuidString,
                permissionConfiguration: permissionConfiguration
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
        let activityKey = "side-chat.\(lease.key.threadID.rawValue).\(lease.key.turnID.rawValue)"
        beginProcessActivity(
            key: activityKey,
            reason: "Running Codex side chat in \(lease.key.threadID.rawValue)"
        )
        sideChatTurnCompletionTask = Task { [weak self] in
            guard let self else { return }
            defer { endProcessActivity(key: activityKey) }
            do {
                _ = try await lease.awaitTerminal()
                guard !Task.isCancelled else { return }
                if activeSideChatTurnLease?.key == lease.key {
                    activeSideChatTurnLease = nil
                }
                if let activity = runtimeSession.finishSideChat(id: lease.key.turnID.rawValue)?.activity {
                    appendActivity(activity)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
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

    func copyWorkingDirectory() {
        copyText(workspacePath)
        appendActivity(.notice, title: "Copied working directory", detail: workspacePath)
    }

    func copySessionID() {
        guard let currentThreadID else {
            appendActivity(.notice, title: "Session ID unavailable", detail: "Open a chat first")
            return
        }
        copyText(currentThreadID)
        appendActivity(.notice, title: "Copied session ID", detail: currentThreadID)
    }

    func handleSlashCommand(
        _ command: CodexSlashCommand,
        presentStatus: (() -> Void)? = nil,
        presentMCPStatus: (() -> Void)? = nil
    ) {
        syncComposerThreadID()
        let route = composerSession.routeSlashCommand(command)
        for activity in route.activities {
            appendActivity(activity)
        }
        for action in route.hostActions {
            applySlashCommandHostAction(
                action,
                presentStatus: presentStatus,
                presentMCPStatus: presentMCPStatus
            )
        }
    }

    private func applySlashCommandHostAction(
        _ action: CodexComposerSlashCommandHostAction,
        presentStatus: (() -> Void)?,
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
        case .forkCurrentChat:
            Task { await forkCurrentChat() }
        case .compactCurrentChat:
            Task { await compactCurrentChat() }
        case .enableGoalPursuit:
            setGoalPursuitEnabled(true)
        case .enablePlanMode:
            configurationSession.setPlanModeEnabled(true)
        case .presentStatus:
            presentStatus?()
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

    func applyFastCommand() {
        let result = configurationSession.applyFastCommandResult()
        if result.didApply {
            rememberManualModelSelection(
                configurationSession.modelSelection,
                tierExplicit: true
            )
        }
        appendActivity(
            .notice,
            title: result.activity.title,
            detail: result.activity.detail
        )
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

    var statusPanelModel: CodexStatusPanelModel {
        CodexStatusPanelModel(
            context: statusSummaryContext,
            rateLimits: accountRateLimitsSnapshot
        )
    }

    var rateLimitBannerMessage: String? {
        guard let accountRateLimitsSnapshot else { return nil }
        return CodexRateLimitPresentation.bannerMessage(for: accountRateLimitsSnapshot)
    }

    var workspaceSummaryContext: CodexWorkspaceSummaryContext {
        var seenSourceIDs: Set<String> = []
        let transcriptSources = transcriptV2.turns.flatMap { turn in
            let messages = [turn.userMessage].compactMap { $0 } + turn.steeredMessages
            return messages.flatMap(\.referencedFiles)
        }
        let sourceFiles = (transcriptSources + referencedFiles)
            .reversed()
            .filter { seenSourceIDs.insert($0.id).inserted }
            .prefix(12)
            .reversed()

        return CodexWorkspaceSummaryContext(
            workspacePath: workspacePath,
            gitBranch: gitBranch,
            turnDiff: currentDiff,
            environmentInfo: environmentInfoState,
            sourceFiles: Array(sourceFiles),
            plan: !isSending && !currentPlan.isEmpty
                ? CodexPlanSummary(steps: currentPlan, explanation: currentPlanExplanation)
                : nil
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
        dictationSession.abort()
        if !keepCurrentThread {
            cancelCurrentThreadObservation()
            activeTurnCompletionTask?.cancel()
            sideChatTurnCompletionTask?.cancel()
            endAllProcessActivities()
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
            configurationSession.clearActiveThreadPermissionConfiguration()
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
        endAllProcessActivities()
        await runtimeSession.disconnect()
        promptRuntime.disconnect()
        cancelCurrentThreadObservation()
        cancelThreadIndexObservation()
        cancelAccountObservation()
        cancelSkillsChangedObservation()
        cancelConnectedSessionBackgroundRefreshes()
        mentionSearchSession.reset()
        structuredPanelDismissalState = CodexStructuredPanelDismissalState()
        configRequirements = nil
        announcedNotificationPromptIDs.removeAll(keepingCapacity: false)
        loginTask?.cancel()
        loginTask = nil
        let previousCodex = codex
        codex = nil
        await previousCodex?.close()
        accountPreferredDisplayName = nil
        authSession.resetAuthentication()
        threadListSession.reset(currentWorkspacePath: workspacePath)
        sidebarNavigationSession.syncCurrentWorkspace(workspacePath, currentThreadID: nil)
        var integrationSession = runtimeSession.integrationCatalogSession
        integrationCatalogRefreshGeneration &+= 1
        integrationSession.reset()
        publishIntegrationCatalogSession(integrationSession)
        runtimeSession.integrationControlPlaneSession.reset()
        pendingPluginActionIDs.removeAll()
        pendingSkillActionIDs.removeAll()
        pendingAppActionIDs.removeAll()
        pendingMarketplaceActionIDs.removeAll()
        marketplaceActionErrors = [:]
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

    private func saveSidebarProjectOrder() {
        CodexProjectOrderStorage.saveProjectOrder(sidebarNavigationSession.projectOrder, to: preferenceStore)
    }

    private func saveSidebarProjectVisibility() {
        CodexHiddenProjectStorage.saveHiddenProjectIDs(
            sidebarNavigationSession.hiddenProjectIDs,
            to: preferenceStore
        )
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
