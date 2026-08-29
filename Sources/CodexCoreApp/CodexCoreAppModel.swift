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
    private(set) var serverDiagnostics: CodexSchemaServerDiagnosticsResponse?
    private(set) var isLoadingServerDiagnostics = false
    private(set) var serverDiagnosticsError: String?
    private(set) var threadUsage: CodexSchemaThreadUsage?
    private(set) var threadUsageThreadID: String?
    private(set) var isLoadingThreadUsage = false
    private(set) var threadUsageError: String?
    private var threadUsageRefreshGeneration = 0
    private(set) var threadSections: [CodexSchemaThreadSection] = []
    private(set) var isLoadingThreadSections = false
    private(set) var threadSectionsError: String?
    private(set) var sidebarActionError: String?
    private(set) var pendingSidebarMutationIDs: Set<String> = []
    private(set) var hooksCatalog = CodexHooksCatalog()
    private(set) var isLoadingHooks = false
    private(set) var hooksError: String?

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
    private var threadQueueObservationTask: Task<Void, Never>?
    private var threadQueueObservationGeneration: UInt64 = 0
    private var pendingDurableQueueSubmissions: [String: CodexComposerSubmission] = [:]
    private var turnAttachmentTask: Task<CodexTurnLease?, Never>?
    private var turnAttachmentKey: TurnKey?
    private var connectedSessionBackgroundTasks: [Task<Void, Never>] = []
    private var sidebarProjectMutationTask: Task<Void, Never>?
    private var sidebarProjectMutationGeneration: UInt64 = 0
    private var integrationCatalogRefreshGeneration: UInt64 = 0
    private var activeTurnCompletionTask: Task<Void, Never>?
    private var sideChatTurnCompletionTask: Task<Void, Never>?
    private var pendingSteerSubmissions: [CodexComposerSubmission] = []
    private var pendingSteerSubmissionHead = 0
    private var isProcessingSteerSubmissions = false
    private var processActivityTokens: [String: NSObjectProtocol] = [:]
    private var announcedNotificationPromptIDs: Set<CodexServerRequestKey> = []
    private(set) var selectedThreadSessionSnapshot: CodexSessionStateSnapshot?
    var threadResourceProjectionCache = CodexThreadResourceProjectionCache()
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
                shouldContinue = authCheck.shouldContinue
            } catch {
                _ = authSession.accountCheckSkipped(message: friendlyError(error))
            }
            startAccountObservation(session: codex.session)
            guard shouldContinue else { return }

            await refreshConnectedSession(using: codex)
        } catch {
            _ = authSession.connectionFailed(message: friendlyError(error))
        }
    }

    func disconnect() async {
        stopAutomationScheduler()
        dictationSession.abort()
        await voiceSession.stop()
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
        cancelThreadQueueObservation()
        cancelConnectedSessionBackgroundRefreshes()
        sidebarProjectMutationTask?.cancel()
        sidebarProjectMutationTask = nil
        sidebarProjectMutationGeneration &+= 1
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
        _ = authSession.disconnected()
    }

    func signOut() async {
        guard let codex else {
            await disconnect()
            return
        }

        do {
            _ = try await codex.perform(CodexRequest.accountLogout())
            await disconnect()
        } catch {
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
            _ = authSession.apiKeyAccepted()
            await refreshConnectedSession(using: codex)
        } catch {
            _ = authSession.apiKeyFailed(message: friendlyError(error))
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
            _ = authSession.deviceCodeStarted(url: verificationURL, code: userCode)
            loginTask?.cancel()
            loginTask = Task { [weak self] in
                do {
                    let completion = try await attempt.completion()
                    guard completion.success else {
                        await CodexMainActorProjection.run {
                            guard let self else { return }
                            _ = self.authSession.deviceCodeEnded(
                                message: completion.error ?? "Device login did not complete"
                            )
                        }
                        return
                    }
                    await self?.finishDeviceCodeLogin()
                } catch {
                    await CodexMainActorProjection.run {
                        guard let self else { return }
                        _ = self.authSession.deviceCodeEnded(message: self.friendlyError(error))
                    }
                }
            }
        } catch {
            _ = authSession.deviceCodeFailed(message: friendlyError(error))
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

        await addDurableQueuedFollowUp(submission)
    }

    func steerQueuedFollowUp(clientID: String) async {
        syncComposerThreadID()
        guard let submission = composerSession.takeQueuedFollowUpSubmission(
                  clientID: clientID,
                  threadID: currentThreadID
              ) else { return }
        guard let codex, let threadID = currentThreadID, let queueID = submission.queueID else {
            composerSession.requeueFollowUp(submission)
            return
        }
        do {
            _ = try await codex.perform(CodexRequest.threadQueueDelete(.init(
                queuedSubmissionID: queueID,
                threadID: threadID
            )))
            await enqueueSteerSubmission(submission)
        } catch {
            composerSession.requeueFollowUp(submission)
        }
    }

    private func addDurableQueuedFollowUp(_ incoming: CodexComposerSubmission) async {
        guard let codex, let threadID = currentThreadID else {
            composerSession.restore(incoming)
            return
        }
        var submission = incoming
        submission.threadID = threadID
        pendingDurableQueueSubmissions[submission.clientID] = submission
        do {
            let response = try await codex.perform(CodexRequest.threadQueueAdd(.init(
                clientUserMessageID: submission.clientID,
                input: submission.turnInput.map { CodexSchemaUserInput($0.jsonValue) },
                threadID: threadID
            )))
            submission.queueID = response.queuedSubmission.id
            submission.queuedInput = response.queuedSubmission.input.map {
                CodexInput(jsonValue: $0.rawValue)
            }
            pendingDurableQueueSubmissions[submission.clientID] = submission
            await refreshDurableQueue(threadID: threadID)
            pendingDurableQueueSubmissions.removeValue(forKey: submission.clientID)
        } catch {
            pendingDurableQueueSubmissions.removeValue(forKey: submission.clientID)
            _ = composerSession.takeQueuedFollowUpSubmission(
                clientID: submission.clientID,
                threadID: threadID
            )
            composerSession.restore(submission)
        }
    }

    private func refreshDurableQueue(threadID: String) async {
        guard let codex else { return }
        do {
            let response = try await codex.perform(CodexRequest.threadQueueList(.init(
                cursor: nil,
                limit: 100,
                threadID: threadID
            )))
            guard !Task.isCancelled, currentThreadID == threadID else { return }
            let existing = composerSession
                .queuedFollowUpSubmissions(for: threadID)
                .reduce(into: [String: CodexComposerSubmission]()) {
                    $0[$1.clientID] = $1
                }
            let submissions = response.data.map { queued -> CodexComposerSubmission in
                var submission = pendingDurableQueueSubmissions[queued.clientUserMessageID]
                    ?? existing[queued.clientUserMessageID]
                    ?? CodexComposerSubmission(queuedSubmission: queued, threadID: threadID)
                submission.threadID = threadID
                submission.queueID = queued.id
                submission.queuedInput = queued.input.map { CodexInput(jsonValue: $0.rawValue) }
                return submission
            }
            composerSession.replaceQueuedFollowUps(submissions, for: threadID)
        } catch {
            guard !Task.isCancelled, currentThreadID == threadID else { return }
        }
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
        Task { [weak self] in await self?.addDurableQueuedFollowUp(submission) }
    }

    func removeQueuedFollowUp(clientID: String) async {
        syncComposerThreadID()
        guard let submission = composerSession.takeQueuedFollowUpSubmission(
            clientID: clientID,
            threadID: currentThreadID
        ) else { return }
        guard let codex, let threadID = currentThreadID, let queueID = submission.queueID else {
            composerSession.requeueFollowUp(submission)
            return
        }
        do {
            _ = try await codex.perform(CodexRequest.threadQueueDelete(.init(
                queuedSubmissionID: queueID,
                threadID: threadID
            )))
            await refreshDurableQueue(threadID: threadID)
        } catch {
            composerSession.requeueFollowUp(submission)
        }
    }

    func editQueuedFollowUp(clientID: String) async {
        syncComposerThreadID()
        guard let submission = composerSession.takeQueuedFollowUpSubmission(
            clientID: clientID,
            threadID: currentThreadID
        ) else { return }
        guard let codex, let threadID = currentThreadID, let queueID = submission.queueID else {
            composerSession.requeueFollowUp(submission)
            return
        }
        do {
            _ = try await codex.perform(CodexRequest.threadQueueDelete(.init(
                queuedSubmissionID: queueID,
                threadID: threadID
            )))
            composerSession.restore(submission)
            await refreshDurableQueue(threadID: threadID)
        } catch {
            composerSession.requeueFollowUp(submission)
        }
    }

    private func startMainTurn(
        _ incomingSubmission: CodexComposerSubmission,
        restoreDraftOnFailure: Bool
    ) async {
        var submission = incomingSubmission
        _ = runtimeSession.beginMainTurnSubmission(submission)
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
            _ = runtimeSession.failMainTurnSubmission(message: friendlyError(error))
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
                automationNotifications.postTurnCompletion(
                    threadID: lease.key.threadID.rawValue,
                    title: currentChatTitle,
                    failure: failed ? terminal.turn.error?.message ?? "The turn failed" : nil
                )
                notifyDockStateChanged()
                Task { await refreshRecentChats() }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                if activeTurnLease?.key == lease.key {
                    activeTurnLease = nil
                }
                _ = runtimeSession.finishMainTurn(id: lease.key.turnID.rawValue)
                let message = friendlyError(error)
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
        } catch {
            composerSession.restore(submission)
        }
    }

    func setGoalPursuitEnabled(_ enabled: Bool) {
        if enabled, isPlanModeEnabled {
            configurationSession.setPlanModeEnabled(false)
        }
        guard goalPursuitEnabled != enabled else { return }
        goalPursuitEnabled = enabled
        if !enabled, selectedThreadGoal != nil {
            Task { await clearCurrentGoal() }
        }
    }

    func handleComposerAddMenuRoute(_ route: CodexComposerAddMenuRoute) {
        guard route.isEnabled else { return }
        for action in route.hostActions {
            handleComposerAddMenuHostAction(action)
        }
    }

    func handleWorktreeHandoffCompletion(_ completion: CodexWorktreeHandoffCompletion) {
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
        case .openFilesAndChats:
            selectAppRoute(.search)
        }
    }

    func addReferencedFileURLs(_ urls: [URL], to threadID: String?) {
        let references = urls.compactMap(CodexReferencedFile.fromDroppedURL)
        guard !references.isEmpty else {
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
        } catch {
            goalPursuitEnabled = true
        }
    }

    private func finishDeviceCodeLogin() async {
        _ = authSession.deviceCodeCompleted()
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
            Task { [weak self] in await self?.refreshThreadSections() },
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

    func applySelectedThreadSnapshotForTesting(
        threadID: String,
        snapshot: CodexSessionStateSnapshot
    ) {
        selectedThreadID = threadID
        applySelectedThreadSnapshot(snapshot)
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
        if selectedThreadID != lease.id.rawValue {
            threadUsageRefreshGeneration += 1
            threadUsage = nil
            threadUsageThreadID = nil
            threadUsageError = nil
            isLoadingThreadUsage = false
        }
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
            Task { [weak self] in
                await self?.refreshBackgroundTerminals()
            }
            await startThreadQueueObservation(
                session: codex.session,
                threadID: lease.id.rawValue
            )
        }
        if let previous, previous !== lease {
            await previous.close()
        }
    }

    private func startCurrentThreadObservation(session: CodexSession, threadID: ThreadID) {
        cancelCurrentThreadObservation()
        currentThreadObservationGeneration &+= 1
        let generation = currentThreadObservationGeneration
        let fields: StateFieldMask = [.thread, .turn, .item, .requests, .backgroundTerminals]
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
        cancelTurnAttachment()
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
                }
            }
        } catch {
        }
    }

    private func cancelSkillsChangedObservation() {
        skillsChangedObservationGeneration &+= 1
        skillsChangedObservationTask?.cancel()
        skillsChangedObservationTask = nil
    }

    private func startThreadQueueObservation(
        session: CodexSession,
        threadID: String
    ) async {
        cancelThreadQueueObservation()
        threadQueueObservationGeneration &+= 1
        let generation = threadQueueObservationGeneration
        do {
            let changes = try await session.observeThreadQueueChanges(threadID: threadID)
            threadQueueObservationTask = Task { [weak self] in
                do {
                    for try await _ in changes {
                        guard !Task.isCancelled,
                              let self,
                              threadQueueObservationGeneration == generation,
                              currentThreadID == threadID
                        else { return }
                        await refreshDurableQueue(threadID: threadID)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard let self,
                          threadQueueObservationGeneration == generation
                    else { return }
                }
            }
            await refreshDurableQueue(threadID: threadID)
        } catch {
        }
    }

    private func cancelThreadQueueObservation() {
        threadQueueObservationGeneration &+= 1
        threadQueueObservationTask?.cancel()
        threadQueueObservationTask = nil
        pendingDurableQueueSubmissions.removeAll(keepingCapacity: true)
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
        _ = authSession.applyCanonicalAccount(account)
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
        if activeTurnLease == nil,
           let runningTurn = turns.last(where: { $0.status == .inProgress }),
           let currentThreadLease {
            Task { [weak self] in
                await self?.attachTurnIfNeeded(
                    runningTurn.key.turnID,
                    to: currentThreadLease
                )
            }
        }
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
        _ = await session.refreshStartupCatalogs(
            using: codex,
            cwds: workspaceRoots,
            errorMessage: CodexErrorFormat.localizedDescription
        )
        guard !Task.isCancelled, self.codex === codex else { return }
        configurationSession.mergeStartupCatalogs(from: session)
        applyPreferredModel(for: currentThreadID)
    }

    func refreshSlashCommands(using codex: Codex, forceReload: Bool = false) async {
        do {
            let response = try await codex.perform(CodexRequest.skillsList(.init(
                cwds: workspaceRoots.isEmpty ? nil : workspaceRoots,
                forceReload: forceReload ? true : nil
            )))
            guard !Task.isCancelled, self.codex === codex else { return }
            _ = configurationSession.applySlashCommandResponse(
                try CodexJSONValue(encoding: response)
            )
        } catch {
            guard !Task.isCancelled, self.codex === codex else { return }
            _ = configurationSession.failSlashCommandRefresh(
                message: CodexErrorFormat.localizedDescription(error)
            )
        }
    }

    func refreshRecentChats() async {
        guard let codex else { return }
        await refreshRecentChats(using: codex)
    }

    private func refreshRecentChats(using codex: Codex) async {
        guard threadListSession.beginThreadListLoad() else { return }
        do {
            let result = try await CodexThreadListSession.fetchRecentChats(
                using: codex,
                currentWorkspacePath: workspacePath
            )
            guard !Task.isCancelled, self.codex === codex else { return }
            threadListSession.applyThreadList(
                currentRaw: result.currentRaw,
                allRaw: result.allRaw,
                currentWorkspacePath: workspacePath
            )
            for (index, page) in result.projectPages.enumerated() {
                threadListSession.applyProjectList(page, reset: index == 0)
            }
        } catch {
            guard !Task.isCancelled, self.codex === codex else { return }
            threadListSession.applyThreadListFailure(
                currentWorkspacePath: workspacePath,
                message: CodexErrorFormat.localizedDescription(error)
            )
        }

        if !hasStoredExpandedProjectState {
            sidebarNavigationSession.setExpandedProjects(
                CodexSidebarNavigationSession.defaultExpandedProjectIDs(projects: threadListSession.recentProjects)
            )
            saveExpandedSidebarProjects()
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
            persistAutomation(id: automation.id)
        case .toggle(let id):
            guard automationLifecycle.toggle(id: id) != nil else { return }
            persistAutomation(id: id)
        case .delete(let id):
            automationRunTasks[id]?.cancel()
            automationRunTasks[id] = nil
            automationLifecycle.delete(id: id)
            do {
                try automationStore.delete(id: id)
                automationNotifications.removePendingRequests(forAutomationID: id)
            } catch {
            }
        case .runNow(let id):
            startAutomationRun(id: id)
        case .learnMore, .createViaChat, .template, .addForChat:
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
        persistAutomation(id: id)

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
            persistAutomation(id: automation.id)
            postAutomationNotification(name: automation.name, failure: message)
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
        persistAutomation(id: automation.id)
        await refreshRecentChats()
        postAutomationNotification(name: automation.name, failure: failure)
    }

    private func persistAutomation(id: String) {
        guard let automation = automations.first(where: { $0.id == id }) else { return }
        try? automationStore.save(automation)
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

    func toggleSidebarSection(_ sectionID: String) {
        sidebarNavigationSession.toggleSection(sectionID)
    }

    func moveSidebarProject(
        _ sourcePath: String,
        relativeTo targetPath: String,
        placement: CodexProjectDropPlacement
    ) {
        let previousOrder = sidebarNavigationSession.projectOrder
        let sourceProject = recentProjects.first {
            $0.workspacePath == CodexProjectSummary.normalizedPath(sourcePath)
        }
        let targetProject = recentProjects.first {
            $0.workspacePath == CodexProjectSummary.normalizedPath(targetPath)
        }
        guard sidebarNavigationSession.moveProject(
            sourcePath,
            relativeTo: targetPath,
            placement: placement,
            among: recentProjects
        ) else { return }
        guard saveSidebarProjectOrder() else {
            sidebarNavigationSession.setProjectOrder(previousOrder)
            sidebarActionError = "The project order could not be saved."
            return
        }
        sidebarActionError = nil

        guard let codex,
              let sourceID = sourceProject?.serverID,
              let targetID = targetProject?.serverID else { return }
        sidebarProjectMutationGeneration &+= 1
        let mutationGeneration = sidebarProjectMutationGeneration
        let orderedProjects = recentProjects.sorted {
            let left = sidebarNavigationSession.projectOrder.firstIndex(of: $0.workspacePath) ?? Int.max
            let right = sidebarNavigationSession.projectOrder.firstIndex(of: $1.workspacePath) ?? Int.max
            return left < right
        }
        let beforeProjectID: String?
        if placement == .before {
            beforeProjectID = targetID
        } else if let targetIndex = orderedProjects.firstIndex(where: { $0.serverID == targetID }) {
            beforeProjectID = orderedProjects.dropFirst(targetIndex + 1).first(where: { $0.serverID != sourceID })?.serverID
        } else {
            beforeProjectID = nil
        }
        let previousMutation = sidebarProjectMutationTask
        sidebarProjectMutationTask = Task { [weak self] in
            guard let self else { return }
            await previousMutation?.value
            guard !Task.isCancelled,
                  sidebarProjectMutationGeneration == mutationGeneration else { return }
            do {
                _ = try await codex.perform(CodexRequest.projectMove(.init(
                    beforeProjectID: beforeProjectID,
                    projectID: sourceID
                )))
            } catch {
                guard CodexSidebarMutation.shouldRollback(
                    operationGeneration: mutationGeneration,
                    currentGeneration: sidebarProjectMutationGeneration
                ) else { return }
                sidebarNavigationSession.setProjectOrder(previousOrder)
                _ = saveSidebarProjectOrder()
                sidebarActionError = friendlyError(error)
            }
        }
    }

    func toggleSidebarProjectPin(_ workspacePath: String) {
        let previous = sidebarNavigationSession.pinnedProjectIDs
        _ = sidebarNavigationSession.toggleProjectPin(workspacePath)
        guard CodexPinnedProjectStorage.savePinnedProjectIDs(
            sidebarNavigationSession.pinnedProjectIDs,
            to: preferenceStore
        ) else {
            sidebarNavigationSession.setPinnedProjectIDs(previous)
            sidebarActionError = "The project pin could not be saved."
            return
        }
        sidebarActionError = nil
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
        var listSession = threadListSession
        listSession.clearServerProjects()
        listSession.refreshProjects(currentWorkspacePath: workspacePath)
        threadListSession = listSession

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
            return
        }
        guard let codex else {
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
                }
            }

            try await voiceSession.start(
                codex: codex,
                threadID: visibleLease.id.rawValue
            )
            await refreshRecentChats(using: codex)
        } catch {
            voiceSession.markFailed(error)
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
            return
        }
        do {
            try await voiceSession.start(codex: codex, threadID: threadID)
            await refreshRecentChats(using: codex)
        } catch {
            voiceSession.markFailed(error)
        }
    }

    func requestComposerFocus() {
        composerFocusRequest &+= 1
    }

    func stopVoiceChat() async {
        await voiceSession.stop()
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
        } catch {
        }
    }

    func searchChats(query: String) async {
        var session = threadListSession
        _ = await session.searchChats(query: query, using: codex, errorMessage: CodexErrorFormat.localizedDescription)
        threadListSession = session
    }

    func clearSearchResults() {
        threadListSession.clearSearch()
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
        _ = await session.refreshMCPServers(
            using: codex,
            threadID: currentThreadID,
            errorMessage: CodexErrorFormat.localizedDescription
        )
        publishIntegrationCatalogSession(session)
    }

    func refreshServerDiagnostics() async {
        guard !isLoadingServerDiagnostics else { return }
        guard let codex else {
            serverDiagnosticsError = "Connect to Codex before reading diagnostics."
            return
        }
        isLoadingServerDiagnostics = true
        serverDiagnosticsError = nil
        defer { isLoadingServerDiagnostics = false }
        do {
            serverDiagnostics = try await codex.perform(
                CodexRequest.serverDiagnostics(.init())
            )
        } catch {
            serverDiagnosticsError = friendlyError(error)
        }
    }

    func refreshThreadUsage() async {
        guard !isLoadingThreadUsage else { return }
        guard let codex, let threadID = currentThreadID else {
            threadUsage = nil
            threadUsageThreadID = nil
            threadUsageError = "Start or open a chat to read its usage estimate."
            return
        }
        isLoadingThreadUsage = true
        threadUsageRefreshGeneration += 1
        let generation = threadUsageRefreshGeneration
        threadUsageError = nil
        defer {
            if threadUsageRefreshGeneration == generation {
                isLoadingThreadUsage = false
            }
        }
        do {
            let response = try await codex.perform(CodexRequest.accountUsageRead(
                .value(.init(threadID: threadID))
            ))
            guard currentThreadID == threadID else { return }
            threadUsage = response.threadUsage
            threadUsageThreadID = response.threadUsage == nil ? nil : threadID
            if response.threadUsage == nil {
                threadUsageError = "Usage estimates are unavailable for this workspace."
            }
        } catch {
            guard currentThreadID == threadID else { return }
            threadUsage = nil
            threadUsageThreadID = nil
            threadUsageError = friendlyError(error)
        }
    }

    func refreshThreadSections() async {
        guard !isLoadingThreadSections else { return }
        guard let codex else {
            threadSectionsError = "Connect to Codex before managing sections."
            return
        }
        isLoadingThreadSections = true
        threadSectionsError = nil
        defer { isLoadingThreadSections = false }
        do {
            var sections: [CodexSchemaThreadSection] = []
            var cursor: String?
            var seenCursors: Set<String> = []
            repeat {
                let response = try await codex.threadSectionList(.init(
                    cursor: cursor,
                    limit: 100
                ))
                sections.append(contentsOf: response.data)
                cursor = response.nextCursor
                if let cursor, !seenCursors.insert(cursor).inserted {
                    throw CodexSDKError.invalidResponse(
                        method: CodexAppServerClientMethod.threadSectionList.rawValue,
                        value: .string("thread section pagination repeated cursor \(cursor)")
                    )
                }
            } while cursor != nil
            threadSections = sections
        } catch {
            threadSectionsError = friendlyError(error)
        }
    }

    func createThreadSection(
        name: String,
        appearance: CodexSchemaThreadSectionAppearance?
    ) async {
        guard let codex else { return }
        do {
            let response = try await codex.threadSectionCreate(.init(
                appearance: appearance,
                name: name
            ))
            upsertThreadSection(response.section)
        } catch {
            threadSectionsError = friendlyError(error)
        }
    }

    func updateThreadSection(
        id: String,
        name: String,
        appearance: CodexAppServerOptionalField<CodexSchemaThreadSectionAppearance>
    ) async {
        guard let codex else { return }
        do {
            let response = try await codex.threadSectionUpdate(.init(
                appearance: appearance,
                name: name,
                sectionID: id
            ))
            upsertThreadSection(response.section)
            await refreshRecentChats(using: codex)
        } catch {
            threadSectionsError = friendlyError(error)
        }
    }

    func deleteThreadSection(id: String) async {
        guard let codex else { return }
        do {
            _ = try await codex.threadSectionDelete(.init(sectionID: id))
            threadSections.removeAll { $0.id == id }
            await refreshRecentChats(using: codex)
        } catch {
            threadSectionsError = friendlyError(error)
        }
    }

    func refreshHooks() async {
        guard !isLoadingHooks else { return }
        guard let provider = integrationControlPlaneProvider else {
            hooksError = "Connect to Codex before inspecting hooks."
            return
        }
        isLoadingHooks = true
        hooksError = nil
        defer { isLoadingHooks = false }
        do {
            let response = try await provider.perform(.hooksList(.init(cwds: workspaceRoots)))
            hooksCatalog = CodexHooksCatalog(raw: response)
        } catch {
            hooksError = friendlyError(error)
        }
    }

    private func upsertThreadSection(_ section: CodexSchemaThreadSection) {
        if let index = threadSections.firstIndex(where: { $0.id == section.id }) {
            threadSections[index] = section
        } else {
            threadSections.append(section)
        }
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
            of: (CodexIntegrationCatalogInventory, CodexIntegrationCatalogSession).self
        ) { group in
            group.addTask {
                var session = initial
                _ = await session.refreshMCPServers(
                    using: codex,
                    threadID: threadID,
                    errorMessage: CodexErrorFormat.localizedDescription
                )
                return (.mcpServers, session)
            }
            group.addTask {
                var session = initial
                _ = await session.refreshPlugins(
                    using: codex,
                    cwds: cwds,
                    errorMessage: CodexErrorFormat.localizedDescription
                )
                return (.plugins, session)
            }
            group.addTask {
                var session = initial
                _ = await session.refreshApps(
                    using: codex,
                    threadID: threadID,
                    errorMessage: CodexErrorFormat.localizedDescription
                )
                return (.apps, session)
            }
            group.addTask {
                var session = initial
                _ = await session.refreshSkills(
                    using: codex,
                    cwds: cwds,
                    forceReload: forceReloadSkills,
                    errorMessage: CodexErrorFormat.localizedDescription
                )
                return (.skills, session)
            }

            for await (inventory, refreshed) in group {
                guard refreshGeneration == integrationCatalogRefreshGeneration else {
                    Self.pluginCatalogLogger.info("discarded stale catalog refresh generation=\(refreshGeneration)")
                    group.cancelAll()
                    return
                }
                var current = runtimeSession.integrationCatalogSession
                current.merge(refreshed, inventory: inventory)
                publishIntegrationCatalogSession(current)
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
        _ = await session.perform(
            request,
            provider: provider,
            errorMessage: CodexErrorFormat.localizedDescription
        )
        runtimeSession.integrationControlPlaneSession = session
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
            return
        }
        setThreadPinned(threadID, pinned: !pinnedThreadIDs.contains(threadID))
    }

    func toggleSidebarChatPin(_ chat: CodexThreadSummary) {
        setThreadPinned(chat.id, pinned: !pinnedThreadIDs.contains(chat.id))
    }

    func toggleSidebarThreadSelection(_ threadID: String) {
        sidebarNavigationSession.toggleThreadSelection(threadID)
    }

    func selectAllSidebarThreads() {
        sidebarNavigationSession.selectThreads(allSidebarChats.map(\.id))
    }

    func clearSidebarThreadSelection() {
        sidebarNavigationSession.clearThreadSelection()
    }

    func togglePinnedSelectedSidebarChats() {
        let selectedIDs = sidebarNavigationSession.selectedThreadIDs
        guard !selectedIDs.isEmpty else { return }
        let shouldPin = selectedIDs.contains { !pinnedThreadIDs.contains($0) }
        for threadID in selectedIDs.sorted() {
            setThreadPinned(threadID, pinned: shouldPin, announces: false)
        }
    }

    func refreshArchivedSidebarChats() async {
        guard let codex else {
            threadListSession.failArchivedLoad(message: "Connect to Codex before browsing archived chats.")
            return
        }
        guard threadListSession.beginArchivedLoad(reset: true) else { return }
        do {
            let response = try await CodexThreadListSession.fetchArchivedPage(using: codex)
            guard !Task.isCancelled, self.codex === codex else { return }
            _ = threadListSession.applyArchivedPage(response, reset: true)
        } catch {
            guard !Task.isCancelled, self.codex === codex else { return }
            threadListSession.failArchivedLoad(message: CodexErrorFormat.localizedDescription(error))
        }
    }

    func loadMoreArchivedSidebarChats() async {
        guard let codex else { return }
        guard let cursor = threadListSession.beginArchivedPageLoad() else { return }
        do {
            let response = try await CodexThreadListSession.fetchArchivedPage(
                using: codex,
                cursor: cursor
            )
            guard !Task.isCancelled, self.codex === codex else { return }
            _ = threadListSession.applyArchivedPage(response)
        } catch {
            guard !Task.isCancelled, self.codex === codex else { return }
            threadListSession.cancelArchivedPageLoad(cursor: cursor)
            threadListSession.failArchivedLoad(message: CodexErrorFormat.localizedDescription(error))
        }
    }

    func unarchiveSidebarChat(_ chat: CodexThreadSummary) async {
        guard let codex else {
            sidebarActionError = "Connect to Codex before restoring chats."
            return
        }
        guard pendingSidebarMutationIDs.insert(chat.id).inserted else { return }
        sidebarActionError = nil
        defer { pendingSidebarMutationIDs.remove(chat.id) }
        do {
            _ = try await codex.perform(CodexRequest.threadUnarchive(.init(threadID: chat.id)))
            var session = threadListSession
            _ = session.removeArchivedThread(id: chat.id)
            threadListSession = session
            await refreshRecentChats(using: codex)
        } catch {
            sidebarActionError = friendlyError(error)
        }
    }

    func moveSidebarChat(
        _ chat: CodexThreadSummary,
        toSectionID sectionID: String?,
        beforeThreadID: String? = nil
    ) async {
        guard let codex else {
            sidebarActionError = "Connect to Codex before moving chats."
            return
        }
        guard pendingSidebarMutationIDs.insert(chat.id).inserted else { return }
        sidebarActionError = nil
        defer { pendingSidebarMutationIDs.remove(chat.id) }
        do {
            _ = try await codex.perform(CodexRequest.threadSectionMove(.init(
                beforeThreadID: beforeThreadID,
                sectionID: sectionID,
                threadID: chat.id
            )))
            await refreshRecentChats(using: codex)
        } catch {
            sidebarActionError = friendlyError(error)
        }
    }

    func archiveSelectedSidebarChats() async {
        guard let codex else {
            sidebarActionError = "Connect to Codex before archiving chats."
            return
        }
        let selectedIDs = sidebarNavigationSession.selectedThreadIDs
        guard !selectedIDs.isEmpty else { return }
        let chats = allSidebarChats.filter { selectedIDs.contains($0.id) }
        let selectedIDAtStart = currentThreadID ?? sidebarNavigationSession.selectedThreadID
        let selectionGenerationAtStart = chatSelectionGeneration
        var archivedIDs: Set<String> = []
        var failures: [String] = []
        var failedIDs: Set<String> = []
        for chat in chats {
            guard pendingSidebarMutationIDs.insert(chat.id).inserted else { continue }
            defer { pendingSidebarMutationIDs.remove(chat.id) }
            do {
                _ = try await codex.perform(CodexRequest.threadArchive(.init(threadID: chat.id)))
                archivedIDs.insert(chat.id)
                setThreadPinned(chat.id, pinned: false, announces: false)
                composerSession.discardThreadState(for: chat.id)
                removeChatFromSidebar(chat.id)
            } catch {
                failures.append("\(chat.title): \(friendlyError(error))")
                failedIDs.insert(chat.id)
            }
        }
        if !failures.isEmpty {
            sidebarActionError = failures.joined(separator: "\n")
        }
        sidebarNavigationSession.clearThreadSelection()
        if !failedIDs.isEmpty {
            sidebarNavigationSession.selectThreads(Array(failedIDs).sorted())
        }
        let selectedIDNow = currentThreadID ?? sidebarNavigationSession.selectedThreadID
        if CodexSidebarArchiveSelectionGuard.shouldClearSelection(
            selectedThreadIDAtStart: selectedIDAtStart,
            currentSelectedThreadID: selectedIDNow,
            selectionGenerationAtStart: selectionGenerationAtStart,
            currentSelectionGeneration: chatSelectionGeneration,
            archivedThreadIDs: archivedIDs
        ) {
            invalidatePendingChatSelection()
            clearThreadState()
            sidebarNavigationSession.syncCurrentWorkspace(workspacePath, currentThreadID: nil)
        }
        await refreshRecentChats(using: codex)
    }

    func archiveSidebarChat(_ chat: CodexThreadSummary) async {
        guard let codex else {
            sidebarActionError = "Connect to Codex before archiving chats."
            return
        }
        guard pendingSidebarMutationIDs.insert(chat.id).inserted else { return }
        defer { pendingSidebarMutationIDs.remove(chat.id) }
        sidebarActionError = nil
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
            sidebarNavigationSession.removeThreadSelections([chat.id])
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
            await refreshRecentChats(using: codex)
        } catch {
            sidebarActionError = friendlyError(error)
        }
    }

    func archiveSidebarProjectChats(_ workspacePath: String) async {
        guard let codex else {
            sidebarActionError = "Connect to Codex before archiving project chats."
            return
        }
        sidebarActionError = nil
        let normalizedPath = CodexProjectSummary.normalizedPath(workspacePath)
        let project = recentProjects.first { $0.workspacePath == normalizedPath }
        let chats = allSidebarChats.filter {
            guard let path = $0.workspacePath else { return false }
            return project?.contains(workspacePath: path)
                ?? (CodexProjectSummary.normalizedPath(path) == normalizedPath)
        }
        guard !chats.isEmpty else {
            return
        }

        let selectedID = currentThreadID ?? sidebarNavigationSession.selectedThreadID
        let archiveGeneration = chatSelectionGeneration
        var archivedIDs: Set<String> = []
        var failures: [String] = []
        for chat in chats {
            guard pendingSidebarMutationIDs.insert(chat.id).inserted else { continue }
            defer { pendingSidebarMutationIDs.remove(chat.id) }
            do {
                _ = try await codex.perform(CodexRequest.threadArchive(.init(threadID: chat.id)))
                archivedIDs.insert(chat.id)
                setThreadPinned(chat.id, pinned: false, announces: false)
                composerSession.discardThreadState(for: chat.id)
                removeChatFromSidebar(chat.id)
            } catch {
                failures.append("\(chat.title): \(friendlyError(error))")
            }
        }
        sidebarActionError = failures.isEmpty ? nil : failures.joined(separator: "\n")

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

        await refreshRecentChats(using: codex)
    }

    func addAutomationForCurrentChat() {
        guard let threadID = currentThreadID else {
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
                _ = try await promptRuntime.resolveApprovalPrompt(id: id, approved: approved)
                notifyDockStateChanged()
            } catch {
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
                _ = try await promptRuntime.resolveApprovalPrompt(id: id, decision: decision)
                notifyDockStateChanged()
            } catch {
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
                _ = try await promptRuntime.submitInteractivePrompt(
                    id: id,
                    answers: answers
                )
                notifyDockStateChanged()
            } catch {
            }
        }
    }

    func acceptInteractivePrompt(id: CodexServerRequestKey) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await promptRuntime.acceptInteractivePrompt(id: id)
                notifyDockStateChanged()
            } catch {
            }
        }
    }

    func declineInteractivePrompt(id: CodexServerRequestKey) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await promptRuntime.declineInteractivePrompt(id: id)
                notifyDockStateChanged()
            } catch {
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
            await refreshRecentChats(using: codex)
        } catch {
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
            await refreshRecentChats(using: codex)
        } catch {
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
            await refreshRecentChats()
        } catch {
        }
    }

    func compactCurrentChat() async {
        guard let codex, let threadID = currentThreadID else {
            return
        }
        do {
            _ = try await codex.perform(CodexRequest.threadCompactStart(.init(threadID: threadID)))
        } catch {
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

            await attachTurnIfNeeded(turn.key.turnID, to: thread)
        } catch {
            guard chatSelectionGeneration == selectionGeneration,
                  currentThreadLease === thread
            else { return }
        }
    }

    private func attachTurnIfNeeded(
        _ turnID: TurnID,
        to thread: CodexThreadLease
    ) async {
        let key = TurnKey(threadID: thread.id, turnID: turnID)
        if activeTurnLease?.key == key { return }
        if turnAttachmentKey == key, let turnAttachmentTask {
            _ = await turnAttachmentTask.value
            return
        }

        cancelTurnAttachment()
        turnAttachmentKey = key
        let task = Task<CodexTurnLease?, Never> {
            try? await thread.attachTurn(turnID)
        }
        turnAttachmentTask = task
        let lease = await task.value
        guard turnAttachmentKey == key else { return }
        turnAttachmentTask = nil
        turnAttachmentKey = nil
        guard currentThreadLease === thread,
              selectedThreadID == thread.id.rawValue,
              let lease else { return }
        activeTurnLease = lease
        runtimeSession.startMainTurn(id: lease.key.turnID.rawValue)
        monitorMainTurn(lease)
    }

    private func cancelTurnAttachment() {
        turnAttachmentTask?.cancel()
        turnAttachmentTask = nil
        turnAttachmentKey = nil
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
        parameters.runtimeWorkspaceRoots = protocolRuntimeRoots([paths.workspaceRoot])
        parameters.developerInstructions = paths.developerInstructions
        return parameters
    }

    func threadResumeParametersForCurrentContext(
        threadID: String
    ) -> CodexSchemaThreadResumeParams {
        var parameters = threadResumeParameters(threadID: threadID)
        if isProjectlessDraft, let paths = projectlessDraftPaths {
            parameters.cwd = paths.cwd
            parameters.runtimeWorkspaceRoots = protocolRuntimeRoots([paths.workspaceRoot])
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
            protocolRuntimeRoots([paths.workspaceRoot])
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
            protocolRuntimeRoots([paths.workspaceRoot])
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
        return lease
    }

    func interrupt() async {
        guard let activeTurnLease else { return }
        do {
            try await activeTurnLease.interrupt()
        } catch {
        }
    }

    func openSideChat() {
        _ = runtimeSession.openSideChat()
    }

    func sendSideChatDraft() async {
        let prompt = composerSession.trimmedSideChatDraft
        guard !prompt.isEmpty else { return }
        composerSession.clearSideChatDraft()
        _ = runtimeSession.beginSideChatSubmission(prompt: prompt)
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
            _ = runtimeSession.failSideChatSubmission(message: friendlyError(error))
        }
    }

    func interruptSideChat() async {
        guard let activeSideChatTurnLease else { return }
        do {
            try await activeSideChatTurnLease.interrupt()
        } catch {
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
                _ = runtimeSession.finishSideChat(id: lease.key.turnID.rawValue)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                if activeSideChatTurnLease?.key == lease.key {
                    activeSideChatTurnLease = nil
                }
                _ = runtimeSession.finishSideChat(id: lease.key.turnID.rawValue)
            }
        }
    }

    func copyChatTranscript() {
        let transcript = CodexChatUtilitySession.transcriptText(transcript: transcriptV2)
        clipboardService.copy(transcript)
    }

    func copyText(_ text: String) {
        clipboardService.copy(text)
    }

    func copyWorkingDirectory() {
        copyText(workspacePath)
    }

    func copySessionID() {
        guard let currentThreadID else {
            return
        }
        copyText(currentThreadID)
    }

    func handleSlashCommand(
        _ command: CodexSlashCommand,
        presentStatus: (() -> Void)? = nil,
        presentMCPStatus: (() -> Void)? = nil
    ) {
        syncComposerThreadID()
        let route = composerSession.routeSlashCommand(command)
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
        case .openModelSelector, .openReasoningSelector:
            break
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
    }

    private func applyReasoningCommand() {
        _ = configurationSession.cycleReasoning()
    }

    /// Refreshes server-owned background terminals for the selected thread.
    /// The protocol operation updates canonical state; UI reads the resulting
    /// snapshot rather than retaining a second process ledger.
    func refreshBackgroundTerminals(threadID: String? = nil) async {
        guard let codex, let threadID = threadID ?? currentThreadID else { return }
        _ = try? await codex.listBackgroundTerminals(threadID: ThreadID(threadID))
    }

    func terminateBackgroundTerminal(processID: String, threadID: String? = nil) async {
        guard let codex, let threadID = threadID ?? currentThreadID else { return }
        _ = try? await codex.terminateBackgroundTerminal(
            threadID: ThreadID(threadID),
            processID: processID
        )
    }

    func cleanBackgroundTerminals(threadID: String? = nil) async {
        guard let codex, let threadID = threadID ?? currentThreadID else { return }
        try? await codex.cleanBackgroundTerminals(threadID: ThreadID(threadID))
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
            rateLimits: accountRateLimitsSnapshot,
            threadUsage: threadUsageThreadID == currentThreadID ? threadUsage : nil,
            isLoadingThreadUsage: isLoadingThreadUsage,
            threadUsageError: threadUsageError
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
                : nil,
            backgroundTerminals: currentThreadID.flatMap {
                selectedThreadSessionSnapshot?.canonical.backgroundTerminals[ThreadID($0)]
            }
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
    }

    private func clearThreadState(
        keepCurrentThread: Bool = false,
        preserveActiveTranscript: Bool = false
    ) {
        dictationSession.abort()
        if !keepCurrentThread {
            cancelCurrentThreadObservation()
            cancelThreadQueueObservation()
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
        endAllProcessActivities()
        await runtimeSession.disconnect()
        promptRuntime.disconnect()
        cancelCurrentThreadObservation()
        cancelThreadIndexObservation()
        cancelAccountObservation()
        cancelSkillsChangedObservation()
        cancelThreadQueueObservation()
        cancelConnectedSessionBackgroundRefreshes()
        mentionSearchSession.reset()
        configRequirements = nil
        serverDiagnostics = nil
        serverDiagnosticsError = nil
        isLoadingServerDiagnostics = false
        threadUsage = nil
        threadUsageThreadID = nil
        threadUsageError = nil
        isLoadingThreadUsage = false
        threadUsageRefreshGeneration += 1
        threadSections = []
        threadSectionsError = nil
        isLoadingThreadSections = false
        sidebarProjectMutationTask?.cancel()
        sidebarProjectMutationTask = nil
        sidebarProjectMutationGeneration &+= 1
        sidebarActionError = nil
        pendingSidebarMutationIDs.removeAll()
        hooksCatalog = .init()
        hooksError = nil
        isLoadingHooks = false
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
        let previous = pinnedThreadIDs
        if pinned {
            pinnedThreadIDs.removeAll { $0 == threadID }
            pinnedThreadIDs.insert(threadID, at: 0)
        } else {
            pinnedThreadIDs.removeAll { $0 == threadID }
        }
        guard CodexPinnedThreadStorage.savePinnedThreadIDs(pinnedThreadIDs, to: preferenceStore) else {
            pinnedThreadIDs = previous
            sidebarActionError = "The chat pin could not be saved."
            return
        }
        sidebarActionError = nil
        guard announces else { return }
    }

    private func saveExpandedSidebarProjects() {
        CodexExpandedProjectStorage.saveExpandedProjectIDs(sidebarNavigationSession.expandedProjectIDs, to: preferenceStore)
        hasStoredExpandedProjectState = true
    }

    @discardableResult
    private func saveSidebarProjectOrder() -> Bool {
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

}
