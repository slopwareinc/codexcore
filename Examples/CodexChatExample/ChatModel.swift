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

private enum CodexInteractivePromptEvent: Sendable {
    case added(CodexInteractivePrompt)
    case resolved(String)
}

private actor CodexInteractivePromptBridge {
    private struct PendingPrompt {
        var prompt: CodexInteractivePrompt
        var continuation: CheckedContinuation<CodexJSONValue, Never>
    }

    private var pendingPrompts: [String: PendingPrompt] = [:]
    private var eventContinuation: AsyncStream<CodexInteractivePromptEvent>.Continuation?

    func events() -> AsyncStream<CodexInteractivePromptEvent> {
        AsyncStream { continuation in
            Task { await self.attach(continuation) }
        }
    }

    func handle(_ request: JSONRPCServerRequest) async -> CodexJSONValue? {
        guard let prompt = CodexInteractivePrompt(serverRequest: request) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            pendingPrompts[prompt.id] = PendingPrompt(prompt: prompt, continuation: continuation)
            eventContinuation?.yield(.added(prompt))
        }
    }

    func resolveUserInput(id: String, answers: [String: String]) {
        guard let pending = pendingPrompts.removeValue(forKey: id) else { return }
        pending.continuation.resume(returning: pending.prompt.userInputResponse(answers: answers))
        eventContinuation?.yield(.resolved(id))
    }

    func acceptElicitation(id: String) {
        guard let pending = pendingPrompts.removeValue(forKey: id) else { return }
        pending.continuation.resume(returning: pending.prompt.acceptElicitationResponse())
        eventContinuation?.yield(.resolved(id))
    }

    func decline(id: String) {
        guard let pending = pendingPrompts.removeValue(forKey: id) else { return }
        pending.continuation.resume(returning: pending.prompt.declineResponse())
        eventContinuation?.yield(.resolved(id))
    }

    func cancelAll() {
        let prompts = pendingPrompts
        pendingPrompts.removeAll()
        for pending in prompts.values {
            pending.continuation.resume(returning: pending.prompt.declineResponse())
            eventContinuation?.yield(.resolved(pending.prompt.id))
        }
    }

    private func attach(_ continuation: AsyncStream<CodexInteractivePromptEvent>.Continuation) async {
        eventContinuation = continuation
        for pending in pendingPrompts.values {
            continuation.yield(.added(pending.prompt))
        }
    }
}

@MainActor
@Observable
final class CodexChatModel {
    typealias ConnectionState = CodexConnectionState
    typealias Message = CodexChatMessage
    typealias Activity = CodexActivity

    var connectionState: ConnectionState = .disconnected
    var workspacePath = defaultWorkspacePath()
    var draft = ""
    var sideChatDraft = ""
    var apiKey = ""
    var messages: [Message] = []
    var lifecycleEvents: [CodexAgentLifecycleEvent] = []
    var sideChat: CodexSideChatState?
    var subagents: [CodexSubagentState] = []
    var recentChats: [CodexThreadSummary] = []
    var recentProjects: [CodexProjectSummary] = CodexProjectSummary.projects(from: [], currentWorkspacePath: defaultWorkspacePath())
    var searchResults: [CodexThreadSearchResult] = []
    var isSearchingChats = false
    var searchErrorMessage: String?
    var mcpServers: [CodexMCPServerStatus] = []
    var isLoadingMCPServers = false
    var mcpErrorMessage: String?
    var plugins: [CodexPluginSummary] = []
    var isLoadingPlugins = false
    var pluginErrorMessage: String?
    var pluginLoadErrors: [String] = []
    var approvalPrompts: [CodexApprovalPrompt] = []
    var interactivePrompts: [CodexInteractivePrompt] = []
    var activities: [Activity] = []
    var isSending = false
    var isSideChatSending = false
    var isAuthenticated = true
    var authLabel = "Checking auth"
    var deviceCodeURL: String?
    var deviceCode: String?
    var themePreset: CodexAgentThemePreset = .officialDark
    var approvalSelection: CodexApprovalSelection = .fullAccess
    var approvalOptions: [CodexApprovalSelection] = CodexApprovalSelection.defaultOptions
    var collaborationModes: [CodexCollaborationModeOption] = CodexCollaborationModeOption.defaultOptions
    var isPlanModeEnabled = false {
        didSet {
            guard isPlanModeEnabled, let reasoning = planModeOption?.reasoning else { return }
            reasoningSelection = reasoning
        }
    }
    var activeGoal: ThreadGoal?
    var isGoalPursuitEnabled = false
    var currentPlan: [TurnPlanStep] = []
    var currentPlanExplanation: String?
    var currentDiff: String?
    var followUpBehavior: CodexFollowUpBehavior = .steer
    var queuedFollowUps: [String] = []
    var mentionResults: [FuzzyFileSearchResult] = []
    private var mentionSearchTask: Task<Void, Never>?
    /// File mentions selected for the current draft, keyed by file name as it
    /// appears in the `@name` token, so we can attach mention input items.
    private var draftMentions: [String: FuzzyFileSearchResult] = [:]
    var modelSelection: CodexModelSelection = .appServerDefault
    var modelOptions: [CodexModelSelection] = CodexModelSelection.defaultOptions
    var reasoningSelection: CodexReasoningSelection = .medium
    var slashCommands: [CodexSlashCommand] = CodexSlashCommand.observedCommands
    var pendingSkillInputs: [CodexSlashCommand] = []

    var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    var isConnecting: Bool {
        if case .connecting = connectionState { return true }
        return false
    }

    var connectionErrorMessage: String? {
        if case .failed(let message) = connectionState { return message }
        return nil
    }

    var serverName: String? {
        if case .connected(let server) = connectionState { return server }
        return nil
    }

    var isThreadReady: Bool {
        thread != nil
    }

    var currentThreadID: String? {
        thread?.id
    }

    var currentChatTitle: String {
        guard let currentThreadID else { return "Current chat" }
        return recentChats.first(where: { $0.id == currentThreadID })?.title ?? "Current chat"
    }

    var showsChatWorkspace: Bool {
        isConnected && isAuthenticated && isThreadReady
    }

    var canUseGoalPursuit: Bool {
        showsChatWorkspace
    }

    private var codex: Codex?
    private var thread: CodexThread?
    private var sideChatThread: CodexThread?
    private var activeTurn: CodexTurnHandle?
    private var activeSideChatTurn: CodexTurnHandle?
    private var activeGoalTurnID: String?
    private var streamTask: Task<Void, Never>?
    private var sideChatStreamTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var approvalEventTask: Task<Void, Never>?
    private var interactivePromptEventTask: Task<Void, Never>?
    private var assistantMessageIDsByItemID: [String: UUID] = [:]
    private var commandMessageIDsByItemID: [String: UUID] = [:]
    private var fileChangeMessageIDsByItemID: [String: UUID] = [:]
    private var planMessageIDsByItemID: [String: UUID] = [:]
    private var toolCallMessageIDsByItemID: [String: UUID] = [:]
    private var noticeMessageIDsByItemID: [String: UUID] = [:]
    private var sideChatAssistantMessageIDsByItemID: [String: UUID] = [:]
    private var sideChatCommandMessageIDsByItemID: [String: UUID] = [:]
    private var sideChatFileChangeMessageIDsByItemID: [String: UUID] = [:]
    private var sideChatPlanMessageIDsByItemID: [String: UUID] = [:]
    private var sideChatToolCallMessageIDsByItemID: [String: UUID] = [:]
    private var sideChatNoticeMessageIDsByItemID: [String: UUID] = [:]
    private var agentStateMapper = CodexAgentStateMapper()
    private var locallyOpenedSideChat: CodexSideChatState?
    private let interactivePromptBridge = CodexInteractivePromptBridge()

    var canSend: Bool {
        if case .connected = connectionState,
           isAuthenticated,
           thread != nil,
           !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !isSending || canSendFollowUp {
            return true
        }
        return false
    }

    /// A turn is running and the draft can be steered into it or queued.
    var canSendFollowUp: Bool {
        isSending && (activeTurn != nil || activeGoalTurnID != nil)
    }

    var followUpHint: String? {
        guard isSending else {
            return queuedFollowUps.isEmpty ? nil : "\(queuedFollowUps.count) queued"
        }
        let queuedSuffix = queuedFollowUps.isEmpty ? "" : " · \(queuedFollowUps.count) queued"
        switch followUpBehavior {
        case .steer:
            return canSendFollowUp ? "↩ steers the current turn\(queuedSuffix)" : nil
        case .queue:
            return canSendFollowUp ? "↩ queues for the next turn\(queuedSuffix)" : nil
        }
    }

    var canSendSideChatMessage: Bool {
        if case .connected = connectionState,
           isAuthenticated,
           thread != nil,
           sideChat != nil,
           !sideChatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !isSideChatSending {
            return true
        }
        return false
    }

    var canUsePlanMode: Bool {
        planModeOption != nil
    }

    private var planModeOption: CodexCollaborationModeOption? {
        collaborationModes.first(where: \.isPlanMode)
    }

    private func turnParameterOverrides() -> [String: CodexJSONValue] {
        var params = approvalSelection.turnParameterOverrides
        if isPlanModeEnabled, let planModeOption {
            params["collaborationMode"] = .string(planModeOption.mode)
        }
        return params
    }

    func connect() async {
        switch connectionState {
        case .connecting, .connected:
            return
        case .disconnected, .failed:
            break
        }

        connectionState = .connecting
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
            let interactivePromptBridge = self.interactivePromptBridge
            let codex = try await Codex(config: config, serverRequestHandler: { request in
                // MCP elicitations are not covered by the approval policy;
                // bridge them into the interactive prompt UI. Everything else
                // falls through (nil) to the SDK's `.ask` flow.
                guard request.method == CodexAppServerServerRequestMethod.mcpServerElicitationRequest.rawValue else {
                    return nil
                }
                return await interactivePromptBridge.handle(request)
            })
            self.codex = codex
            consumeGlobalNotifications(codex)
            startApprovalStoreMirror()
            let server = codex.metadata.serverInfo?.name ?? "Codex"
            connectionState = .connected(server: server)

            do {
                let account = try await codex.account(refreshToken: false)
                isAuthenticated = account.account != nil || !account.requiresOpenAIAuth
                if let accountInfo = account.account {
                    authLabel = accountInfo.email.map { "\(accountInfo.type) · \($0)" } ?? accountInfo.type
                    appendActivity(.login, title: "Signed in", detail: authLabel)
                } else if account.requiresOpenAIAuth {
                    authLabel = "Sign-in required"
                    appendActivity(.login, title: "Authentication required", detail: "Sign in to continue")
                    return
                } else {
                    authLabel = "Available"
                }
            } catch {
                authLabel = "Account check skipped"
                appendActivity(.login, title: "Account check skipped", detail: friendlyError(error))
            }

            await refreshPermissionProfiles(using: codex)
            await refreshCollaborationModes(using: codex)
            await refreshModelOptions(using: codex)
            await refreshSlashCommands(using: codex)
            try await ensureThread()
            await refreshRecentChats(using: codex)
        } catch {
            connectionState = .failed(friendlyError(error))
            appendActivity(.notice, title: "Connection failed", detail: friendlyError(error))
        }
    }

    func disconnect() async {
        streamTask?.cancel()
        sideChatStreamTask?.cancel()
        notificationTask?.cancel()
        loginTask?.cancel()
        await interactivePromptBridge.cancelAll()
        streamTask = nil
        sideChatStreamTask = nil
        notificationTask = nil
        loginTask = nil
        approvalEventTask?.cancel()
        interactivePromptEventTask?.cancel()
        approvalEventTask = nil
        interactivePromptEventTask = nil
        activeTurn = nil
        activeSideChatTurn = nil
        isSending = false
        isSideChatSending = false
        thread = nil
        sideChatThread = nil
        approvalPrompts = []
        interactivePrompts = []
        let codex = self.codex
        self.codex = nil
        await codex?.close()
        connectionState = .disconnected
        appendActivity(.notice, title: "Disconnected", detail: "Closed app-server session")
    }

    func loginWithAPIKey() async {
        guard let codex else { return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try await codex.loginAPIKey(key)
            apiKey = ""
            isAuthenticated = true
            authLabel = "OpenAI API key"
            appendActivity(.login, title: "API key accepted", detail: "Authentication updated")
            await refreshPermissionProfiles(using: codex)
            await refreshCollaborationModes(using: codex)
            await refreshModelOptions(using: codex)
            await refreshSlashCommands(using: codex)
            try await ensureThread()
            await refreshRecentChats(using: codex)
        } catch {
            appendActivity(.login, title: "API key login failed", detail: friendlyError(error))
        }
    }

    func startDeviceCodeLogin() async {
        guard let codex else { return }
        do {
            let handle = try await codex.loginChatGPTDeviceCode()
            deviceCodeURL = handle.verificationUrl
            deviceCode = handle.userCode
            appendActivity(.login, title: "Device login started", detail: "Code \(handle.userCode)")
            loginTask?.cancel()
            loginTask = Task { [weak self] in
                do {
                    _ = try await handle.wait()
                    await self?.finishDeviceCodeLogin()
                } catch {
                    await MainActor.run {
                        self?.appendActivity(.login, title: "Device login ended", detail: self?.friendlyError(error) ?? "")
                    }
                }
            }
        } catch {
            appendActivity(.login, title: "Device login failed", detail: friendlyError(error))
        }
    }

    func sendDraft() async {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        if canSendFollowUp {
            await sendFollowUp(prompt: prompt)
            return
        }
        let skillInputs = pendingSkillInputs
        if isGoalPursuitEnabled {
            await sendGoalDraft(prompt: prompt, skills: skillInputs)
            return
        }
        let mentionInputs = mentionInputItems(for: prompt)
        draft = ""
        pendingSkillInputs = []
        draftMentions = [:]
        mentionResults = []
        isSending = true
        let skillDetail = skillInputs.isEmpty ? nil : "Skills: \(skillInputs.map(\.title).joined(separator: ", "))"
        appendMessage(.user, prompt, detail: skillDetail)
        appendActivity(.turn, title: "You asked Codex", detail: skillDetail.map { "\($0) · \(prompt)" } ?? prompt)

        do {
            let thread = try await ensureThread()
            let handle = try await thread.turn(
                turnInput(prompt: prompt, skills: skillInputs, mentions: mentionInputs),
                approvalMode: approvalSelection.approvalMode,
                cwd: workspacePath,
                effort: reasoningSelection.effort,
                model: modelSelection.modelIdentifier,
                sandbox: approvalSelection.sandbox,
                params: turnParameterOverrides()
            )
            activeTurn = handle
            consumeTurn(handle)
        } catch {
            isSending = false
            pendingSkillInputs = skillInputs + pendingSkillInputs
            appendMessage(.system, "Failed to start turn: \(friendlyError(error))")
            appendActivity(.turn, title: "Turn failed to start", detail: friendlyError(error))
        }
    }

    /// Handles send while a turn is already running: steer it immediately or
    /// queue the message for the next turn, per `followUpBehavior`.
    private func sendFollowUp(prompt: String) async {
        draft = ""

        // Goal turns have no turn handle to steer; queue instead.
        let steerableTurn = followUpBehavior == .steer ? activeTurn : nil
        guard let steerableTurn else {
            queuedFollowUps.append(prompt)
            appendMessage(.user, prompt, detail: "Queued")
            appendActivity(.turn, title: "Follow-up queued", detail: prompt)
            return
        }

        appendMessage(.user, prompt, detail: "Steered")
        appendActivity(.turn, title: "Steering turn", detail: prompt)
        do {
            _ = try await steerableTurn.steer(prompt)
        } catch {
            // The turn may have completed while we were sending; don't lose
            // the message — queue it for the next turn instead.
            queuedFollowUps.append(prompt)
            appendActivity(.turn, title: "Steer failed — queued instead", detail: friendlyError(error))
        }
    }

    /// Sends the next queued follow-up as a fresh turn. Called after a turn
    /// finishes; messages were already rendered when they were queued.
    private func flushQueuedFollowUps() {
        guard !queuedFollowUps.isEmpty, !isSending else { return }
        let prompt = queuedFollowUps.removeFirst()
        isSending = true
        appendActivity(.turn, title: "Sending queued follow-up", detail: prompt)

        Task { [weak self] in
            guard let self else { return }
            do {
                let thread = try await ensureThread()
                let handle = try await thread.turn(
                    turnInput(prompt: prompt, skills: []),
                    approvalMode: approvalSelection.approvalMode,
                    cwd: workspacePath,
                    effort: reasoningSelection.effort,
                    model: modelSelection.modelIdentifier,
                    sandbox: approvalSelection.sandbox,
                    params: turnParameterOverrides()
                )
                await MainActor.run {
                    self.activeTurn = handle
                    self.consumeTurn(handle)
                }
            } catch {
                await MainActor.run {
                    self.isSending = false
                    self.queuedFollowUps.insert(prompt, at: 0)
                    self.appendActivity(.turn, title: "Queued follow-up failed to start", detail: self.friendlyError(error))
                }
            }
        }
    }

    private func sendGoalDraft(prompt: String, skills skillInputs: [CodexSlashCommand]) async {
        draft = ""
        pendingSkillInputs = []
        isSending = true
        let skillDetail = skillInputs.isEmpty ? "Goal" : "Goal · Skills: \(skillInputs.map(\.title).joined(separator: ", "))"
        appendMessage(.user, prompt, detail: skillDetail)
        appendActivity(.turn, title: "Pursuing goal", detail: prompt)

        do {
            let thread = try await ensureThread()
            let response = try await thread.setGoal(objective: prompt, status: .active)
            applyGoal(response.goal, turnID: nil)
            appendActivity(.notice, title: "Goal started", detail: goalProgressSummary(response.goal))
        } catch {
            isSending = false
            draft = prompt
            pendingSkillInputs = skillInputs + pendingSkillInputs
            appendMessage(.system, "Failed to start goal: \(friendlyError(error))")
            appendActivity(.turn, title: "Goal failed to start", detail: friendlyError(error))
        }
    }

    func setGoalPursuitEnabled(_ enabled: Bool) {
        guard enabled != isGoalPursuitEnabled else { return }
        isGoalPursuitEnabled = enabled
        if enabled {
            appendActivity(.notice, title: "Goal mode enabled", detail: activeGoal?.objective ?? "Next message becomes a goal")
        } else if activeGoal != nil {
            Task { await clearCurrentGoal() }
        } else {
            appendActivity(.notice, title: "Goal mode disabled", detail: "Composer returned to chat mode")
        }
    }

    func clearCurrentGoal() async {
        guard let thread, activeGoal != nil else {
            activeGoal = nil
            isGoalPursuitEnabled = false
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
            isGoalPursuitEnabled = true
        }
    }

    private func finishDeviceCodeLogin() async {
        isAuthenticated = true
        authLabel = "ChatGPT"
        deviceCode = nil
        deviceCodeURL = nil
        appendActivity(.login, title: "Signed in with ChatGPT", detail: "Authentication updated")
        do {
            if let codex {
                await refreshPermissionProfiles(using: codex)
                await refreshCollaborationModes(using: codex)
                await refreshModelOptions(using: codex)
                await refreshSlashCommands(using: codex)
            }
            try await ensureThread()
            if let codex {
                await refreshRecentChats(using: codex)
            }
        } catch {
            appendActivity(.turn, title: "Thread creation failed", detail: friendlyError(error))
        }
    }

    private func refreshPermissionProfiles(using codex: Codex) async {
        do {
            let raw = try await codex.permissionProfileListRaw()
            let profiles = CodexPermissionProfileSummary.profiles(from: raw)
            let options = CodexApprovalSelection.options(from: profiles)
            approvalOptions = options
            if !options.contains(approvalSelection) {
                approvalSelection = options.contains(.fullAccess) ? .fullAccess : (options.first ?? .approveForMe)
            }
            appendActivity(.notice, title: "Loaded access profiles", detail: "\(profiles.count) app-server profiles")
        } catch {
            approvalOptions = CodexApprovalSelection.defaultOptions
            appendActivity(.notice, title: "Access profiles unavailable", detail: friendlyError(error))
        }
    }

    private func refreshCollaborationModes(using codex: Codex) async {
        do {
            let raw = try await codex.collaborationModeListRaw()
            let modes = CodexCollaborationModeOption.options(from: raw)
            collaborationModes = modes
            if isPlanModeEnabled, planModeOption == nil {
                isPlanModeEnabled = false
            } else if isPlanModeEnabled, let reasoning = planModeOption?.reasoning {
                reasoningSelection = reasoning
            }
            appendActivity(.notice, title: "Loaded collaboration modes", detail: "\(modes.count) app-server modes")
        } catch {
            collaborationModes = CodexCollaborationModeOption.defaultOptions
            appendActivity(.notice, title: "Collaboration modes unavailable", detail: friendlyError(error))
        }
    }

    private func refreshModelOptions(using codex: Codex) async {
        do {
            let response = try await codex.models(includeHidden: false)
            let options = CodexModelSelection.options(from: response)
            guard !options.isEmpty else {
                modelOptions = CodexModelSelection.defaultOptions
                selectModel(.appServerDefault)
                appendActivity(.notice, title: "Model list empty", detail: "Using app-server default model")
                return
            }

            modelOptions = options
            let selectedModel: CodexModelSelection
            if let current = options.first(where: { option in
                option.id == modelSelection.id ||
                    (option.modelIdentifier != nil && option.modelIdentifier == modelSelection.modelIdentifier)
            }) {
                selectedModel = current
            } else if let defaultOption = options.first(where: \.isDefault) {
                selectedModel = defaultOption
            } else if let first = options.first {
                selectedModel = first
            } else {
                selectedModel = modelSelection
            }
            selectModel(selectedModel)
            appendActivity(.notice, title: "Loaded models", detail: "\(options.count) app-server models")
        } catch {
            modelOptions = CodexModelSelection.defaultOptions
            appendActivity(.notice, title: "Model list unavailable", detail: friendlyError(error))
        }
    }

    private func selectModel(_ selection: CodexModelSelection) {
        modelSelection = selection
        let supported = selection.supportedReasoning.isEmpty
            ? CodexReasoningSelection.defaultOptions
            : selection.supportedReasoning
        if !supported.contains(reasoningSelection) {
            if let defaultReasoning = selection.defaultReasoning, supported.contains(defaultReasoning) {
                reasoningSelection = defaultReasoning
            } else {
                reasoningSelection = supported.first ?? .medium
            }
        }
    }

    private func refreshSlashCommands(forceReload: Bool = false) async {
        guard let codex else { return }
        await refreshSlashCommands(using: codex, forceReload: forceReload)
    }

    private func refreshSlashCommands(using codex: Codex, forceReload: Bool = false) async {
        do {
            let raw = try await codex.skillsListRaw(cwds: [workspacePath], forceReload: forceReload)
            let skillCommands = CodexSlashCommand.skillCommands(from: raw)
            slashCommands = CodexSlashCommand.observedCommands + skillCommands
            appendActivity(.notice, title: "Loaded skills", detail: "\(skillCommands.count) app-server skills")
        } catch {
            slashCommands = CodexSlashCommand.observedCommands
            appendActivity(.notice, title: "Skill list unavailable", detail: friendlyError(error))
        }
    }

    func refreshRecentChats() async {
        guard let codex else { return }
        await refreshRecentChats(using: codex)
    }

    private func refreshRecentChats(using codex: Codex) async {
        do {
            let currentRaw = try await codex.threadListRaw(params: [
                "archived": .bool(false),
                "cwd": .string(workspacePath),
                "limit": .int(50),
                "sortDirection": .string(SortDirection.desc.rawValue),
                "sortKey": .string(ThreadSortKey.updatedAt.rawValue)
            ])
            let allRaw = try await codex.threadListRaw(params: [
                "archived": .bool(false),
                "limit": .int(100),
                "sortDirection": .string(SortDirection.desc.rawValue),
                "sortKey": .string(ThreadSortKey.updatedAt.rawValue)
            ])
            let currentChats = Self.visibleThreadSummaries(from: currentRaw)
            let allChats = Self.mergedThreadSummaries(currentChats + Self.visibleThreadSummaries(from: allRaw))
            recentChats = currentChats
            recentProjects = CodexProjectSummary.projects(from: allChats, currentWorkspacePath: workspacePath)
        } catch {
            appendActivity(.notice, title: "Chat list unavailable", detail: friendlyError(error))
            recentProjects = CodexProjectSummary.projects(from: recentChats, currentWorkspacePath: workspacePath)
        }
    }

    func switchWorkspace(to path: String) async {
        let normalized = CodexProjectSummary.normalizedPath(path)
        guard !normalized.isEmpty else { return }
        guard normalized != CodexProjectSummary.normalizedPath(workspacePath) else { return }

        workspacePath = normalized
        clearThreadState()
        appendActivity(.notice, title: "Switched project", detail: normalized)

        guard let codex else {
            recentProjects = CodexProjectSummary.projects(from: recentChats, currentWorkspacePath: workspacePath)
            return
        }

        do {
            try await ensureThread()
            await refreshSlashCommands(using: codex)
            await refreshRecentChats(using: codex)
        } catch {
            appendMessage(.system, "Failed to open project: \(friendlyError(error))")
            appendActivity(.notice, title: "Project switch failed", detail: friendlyError(error))
        }
    }

    func startNewChat() async {
        guard codex != nil else { return }
        clearThreadState()
        do {
            try await ensureThread()
            await refreshRecentChats()
        } catch {
            appendMessage(.system, "Failed to start chat: \(friendlyError(error))")
            appendActivity(.turn, title: "New chat failed", detail: friendlyError(error))
        }
    }

    func resumeChat(id threadID: String) async {
        guard let codex else { return }
        guard thread?.id != threadID else { return }
        clearThreadState()
        do {
            let resumedThread = try await codex.threadResume(
                threadID,
                approvalMode: approvalSelection.approvalMode,
                cwd: workspacePath,
                model: modelSelection.modelIdentifier,
                sandbox: approvalSelection.sandbox
            )
            thread = resumedThread
            await hydrateThreadHistory(for: resumedThread, using: codex)
            await refreshGoal(for: resumedThread)
            appendActivity(.notice, title: "Resumed chat", detail: threadID)
            await refreshRecentChats(using: codex)
        } catch {
            appendMessage(.system, "Failed to resume chat: \(friendlyError(error))")
            appendActivity(.notice, title: "Resume failed", detail: friendlyError(error))
        }
    }

    func searchChats(query: String) async {
        let searchTerm = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchTerm.isEmpty else {
            searchResults = []
            searchErrorMessage = nil
            return
        }
        guard let codex else {
            searchResults = []
            searchErrorMessage = "Connect to Codex before searching."
            return
        }

        isSearchingChats = true
        searchErrorMessage = nil
        do {
            let raw = try await codex.threadSearchRaw(searchTerm: searchTerm, limit: 25)
            searchResults = CodexThreadSearchResult.results(from: raw)
            appendActivity(.notice, title: "Searched chats", detail: "\(searchResults.count) matches for \(searchTerm)")
        } catch {
            searchResults = []
            searchErrorMessage = friendlyError(error)
            appendActivity(.notice, title: "Search failed", detail: friendlyError(error))
        }
        isSearchingChats = false
    }

    func clearSearchResults() {
        searchResults = []
        searchErrorMessage = nil
        isSearchingChats = false
    }

    func refreshMCPServers() async {
        guard let codex else {
            mcpServers = []
            mcpErrorMessage = "Connect to Codex before inspecting MCP servers."
            return
        }

        isLoadingMCPServers = true
        mcpErrorMessage = nil
        do {
            let raw = try await codex.mcpServerStatusListRaw(threadId: currentThreadID, detail: "full", limit: 100)
            mcpServers = CodexMCPServerStatus.statuses(from: raw)
            appendActivity(.notice, title: "Loaded MCP servers", detail: "\(mcpServers.count) configured")
        } catch {
            mcpServers = []
            mcpErrorMessage = friendlyError(error)
            appendActivity(.notice, title: "MCP status unavailable", detail: friendlyError(error))
        }
        isLoadingMCPServers = false
    }

    func refreshPlugins() async {
        guard let codex else {
            plugins = []
            pluginLoadErrors = []
            pluginErrorMessage = "Connect to Codex before inspecting plugins."
            return
        }

        isLoadingPlugins = true
        pluginErrorMessage = nil
        do {
            let raw = try await codex.pluginListRaw(cwds: [workspacePath])
            plugins = CodexPluginSummary.plugins(from: raw)
            pluginLoadErrors = CodexPluginSummary.loadErrorMessages(from: raw)
            appendActivity(.notice, title: "Loaded plugins", detail: "\(plugins.count) available")
        } catch {
            plugins = []
            pluginLoadErrors = []
            pluginErrorMessage = friendlyError(error)
            appendActivity(.notice, title: "Plugin list unavailable", detail: friendlyError(error))
        }
        isLoadingPlugins = false
    }

    func resolveApprovalPrompt(id: String, approved: Bool) {
        Task { [weak self] in
            guard let self else { return }
            let decision: CodexApprovalDecision = approved ? .accept : .decline
            let resolved = await codex?.respondToApproval(id: id, decision: decision) ?? false
            if resolved {
                await MainActor.run {
                    approvalPrompts.removeAll(where: { $0.id == id })
                    appendActivity(.notice, title: "Approval resolved", detail: id)
                }
            }
        }
    }

    func submitInteractivePrompt(id: String, answers: [String: String]) {
        if promptKind(forInteractivePromptID: id) == .userInput {
            Task { [weak self] in
                guard let self else { return }
                let resolved = await codex?.respondToUserInput(id: id, answers: answers.mapValues { [$0] }) ?? false
                if resolved {
                    await MainActor.run { interactivePrompts.removeAll(where: { $0.id == id }) }
                }
            }
            return
        }
        Task { await interactivePromptBridge.resolveUserInput(id: id, answers: answers) }
    }

    func acceptInteractivePrompt(id: String) {
        Task { await interactivePromptBridge.acceptElicitation(id: id) }
    }

    func declineInteractivePrompt(id: String) {
        if promptKind(forInteractivePromptID: id) == .userInput {
            Task { [weak self] in
                guard let self else { return }
                let resolved = await codex?.respondToUserInput(id: id, answers: [:]) ?? false
                if resolved {
                    await MainActor.run { interactivePrompts.removeAll(where: { $0.id == id }) }
                }
            }
            return
        }
        Task { await interactivePromptBridge.decline(id: id) }
    }

    private func promptKind(forInteractivePromptID id: String) -> CodexInteractivePromptKind? {
        interactivePrompts.first(where: { $0.id == id })?.kind
    }

    func resumeSearchResult(_ result: CodexThreadSearchResult) async {
        let workspace = result.thread.workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let workspace, !workspace.isEmpty {
            let normalized = CodexProjectSummary.normalizedPath(workspace)
            if normalized != CodexProjectSummary.normalizedPath(workspacePath) {
                workspacePath = normalized
                clearThreadState()
                appendActivity(.notice, title: "Switched project", detail: normalized)
            }
        }
        await resumeChat(id: result.thread.id)
    }

    func forkCurrentChat() async {
        guard let codex, let thread else { return }
        let sourceID = thread.id
        clearThreadState()
        do {
            let forkedThread = try await codex.threadFork(
                sourceID,
                approvalMode: approvalSelection.approvalMode,
                cwd: workspacePath,
                ephemeral: false,
                model: modelSelection.modelIdentifier,
                sandbox: approvalSelection.sandbox
            )
            self.thread = forkedThread
            await hydrateThreadHistory(for: forkedThread, using: codex)
            appendActivity(.notice, title: "Forked chat", detail: sourceID)
            await refreshRecentChats(using: codex)
        } catch {
            appendMessage(.system, "Failed to fork chat: \(friendlyError(error))")
            appendActivity(.notice, title: "Fork failed", detail: friendlyError(error))
        }
    }

    func archiveCurrentChat() async {
        guard let codex, let thread else { return }
        let archivedID = thread.id
        do {
            _ = try await codex.threadArchive(archivedID)
            clearThreadState()
            appendActivity(.notice, title: "Archived chat", detail: archivedID)
            try await ensureThread()
            await refreshRecentChats(using: codex)
        } catch {
            appendActivity(.notice, title: "Archive failed", detail: friendlyError(error))
        }
    }

    func renameCurrentChat(to name: String) async {
        guard let thread else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await thread.setName(trimmed)
            appendActivity(.notice, title: "Renamed chat", detail: trimmed)
            await refreshRecentChats()
        } catch {
            appendActivity(.notice, title: "Rename failed", detail: friendlyError(error))
        }
    }

    func compactCurrentChat() async {
        guard let thread else {
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
        if let thread { return thread }
        guard let codex else { throw CodexSDKError.runtimeNotFound }
        let thread = try await codex.threadStart(
            approvalMode: approvalSelection.approvalMode,
            cwd: workspacePath,
            model: modelSelection.modelIdentifier,
            sandbox: approvalSelection.sandbox
        )
        self.thread = thread
        await refreshGoal(for: thread)
        appendActivity(.notice, title: "Thread ready", detail: "Workspace session created")
        return thread
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
            let raw = try await codex.rawRequest(
                method: CodexAppServerClientMethod.threadRead.rawValue,
                params: [
                    "threadId": .string(thread.id),
                    "includeTurns": .bool(true)
                ]
            )
            var snapshot = CodexThreadHistorySnapshot(raw: raw)
            let restoredChildThreads = await hydrateChildThreadHistories(in: &snapshot, using: codex)
            messages = snapshot.messages
            agentStateMapper = snapshot.agentStateMapper
            locallyOpenedSideChat = nil
            syncAgentState()
            let agentDetail = restoredChildThreads > 0 ? ", \(restoredChildThreads) agents restored" : ""
            appendActivity(.notice, title: "Loaded transcript", detail: "\(messages.count) messages restored\(agentDetail)")
        } catch {
            appendActivity(.notice, title: "Transcript unavailable", detail: friendlyError(error))
            if messages.isEmpty {
                appendMessage(.system, "Unable to load prior transcript: \(friendlyError(error))")
            }
        }
    }

    private func hydrateChildThreadHistories(in snapshot: inout CodexThreadHistorySnapshot, using codex: Codex) async -> Int {
        var restoredCount = 0
        var seenThreadIDs: Set<String> = []
        for childThreadID in snapshot.subagentThreadIDs where seenThreadIDs.insert(childThreadID).inserted {
            do {
                let raw = try await codex.rawRequest(
                    method: CodexAppServerClientMethod.threadRead.rawValue,
                    params: [
                        "threadId": .string(childThreadID),
                        "includeTurns": .bool(true)
                    ]
                )
                if snapshot.applyChildThread(raw: raw, threadID: childThreadID) {
                    restoredCount += 1
                }
            } catch {
                continue
            }
        }
        return restoredCount
    }

    @discardableResult
    private func ensureSideChatThread() async throws -> CodexThread {
        if let sideChatThread { return sideChatThread }
        guard let codex else { throw CodexSDKError.runtimeNotFound }
        let parentThread = try await ensureThread()
        let forked = try await codex.threadFork(
            parentThread.id,
            approvalMode: approvalSelection.approvalMode,
            cwd: workspacePath,
            ephemeral: true,
            model: modelSelection.modelIdentifier,
            sandbox: approvalSelection.sandbox
        )
        sideChatThread = forked
        appendActivity(.notice, title: "Side chat ready", detail: "Forked focused branch")
        return forked
    }

    func interrupt() async {
        if let activeTurn {
            do {
                _ = try await activeTurn.interrupt()
                appendActivity(.turn, title: "Interrupt sent", detail: "Stopping the current turn")
            } catch {
                appendActivity(.turn, title: "Interrupt failed", detail: friendlyError(error))
            }
            return
        }

        guard let thread, let activeGoalTurnID else { return }
        do {
            _ = try await thread.interrupt(turnId: activeGoalTurnID)
            appendActivity(.turn, title: "Interrupt sent", detail: "Stopping the current turn")
        } catch {
            appendActivity(.turn, title: "Interrupt failed", detail: friendlyError(error))
        }
    }

    func openSideChat() {
        if locallyOpenedSideChat == nil {
            locallyOpenedSideChat = CodexSideChatState(createdAt: Date())
            appendActivity(.notice, title: "Opened side chat", detail: "Focused branch ready")
        } else {
            appendActivity(.notice, title: "Opened side chat", detail: "Focused branch already available")
        }
        syncAgentState()
    }

    func sendSideChatDraft() async {
        let prompt = sideChatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        openSideChat()
        sideChatDraft = ""
        isSideChatSending = true
        appendLocalSideChatMessage(.user, prompt)
        appendActivity(.turn, title: "Side chat asked", detail: prompt)

        do {
            let thread = try await ensureSideChatThread()
            let handle = try await thread.turn(
                [.text(prompt)],
                approvalMode: approvalSelection.approvalMode,
                cwd: workspacePath,
                effort: reasoningSelection.effort,
                model: modelSelection.modelIdentifier,
                sandbox: approvalSelection.sandbox,
                params: turnParameterOverrides()
            )
            activeSideChatTurn = handle
            consumeSideChatTurn(handle)
        } catch {
            isSideChatSending = false
            appendLocalSideChatMessage(.system, "Failed to start side chat: \(friendlyError(error))")
            appendActivity(.turn, title: "Side chat failed to start", detail: friendlyError(error))
        }
    }

    func interruptSideChat() async {
        guard let activeSideChatTurn else { return }
        do {
            _ = try await activeSideChatTurn.interrupt()
            appendActivity(.turn, title: "Side chat interrupt sent", detail: "Stopping the side chat turn")
        } catch {
            appendActivity(.turn, title: "Side chat interrupt failed", detail: friendlyError(error))
        }
    }

    func copyChatTranscript() {
        let transcript = formattedTranscript()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)

        let detail = messages.isEmpty ? "No transcript text yet" : "\(messages.count) messages copied"
        appendActivity(.notice, title: "Copied chat", detail: detail)
    }

    func handleSlashCommand(_ command: CodexSlashCommand, presentMCPStatus: (() -> Void)? = nil) {
        if let skillName = command.skillName, let skillPath = command.skillPath {
            draft = command.draftText ?? ""
            if !pendingSkillInputs.contains(where: { $0.skillName == skillName && $0.skillPath == skillPath }) {
                pendingSkillInputs.append(command)
            }
            appendActivity(.notice, title: "Skill attached", detail: command.title)
            return
        }

        switch command.id {
        case "side":
            draft = ""
            openSideChat()
        case "fast":
            draft = ""
            applyFastCommand()
        case "reasoning":
            draft = ""
            applyReasoningCommand()
        case "model":
            draft = ""
            appendActivity(
                .notice,
                title: "Model",
                detail: "\(modelSelection.displayName) \(reasoningSelection.displayName)"
            )
        case "status":
            draft = ""
            appendMessage(.system, currentStatusSummary(), detail: "status")
            appendActivity(.notice, title: "Status", detail: connectionState.label)
        case "fork":
            draft = ""
            Task { await forkCurrentChat() }
        case "compact":
            draft = ""
            Task { await compactCurrentChat() }
        case "mcp":
            draft = ""
            presentMCPStatus?()
            Task { await refreshMCPServers() }
        case "pet":
            draft = ""
            appendActivity(.notice, title: "Pet", detail: "Pet controls are not available in this example yet")
        default:
            if let draftText = command.draftText {
                draft = draftText
                appendActivity(.notice, title: "Slash command", detail: "Prepared \(command.title)")
            } else {
                draft = ""
                appendActivity(.notice, title: "Slash command", detail: command.title)
            }
        }
    }

    private func consumeTurn(_ handle: CodexTurnHandle) {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            let turnID = handle.id
            for await notification in handle.stream() {
                self.apply(notification)
            }
            await MainActor.run {
                _ = self.finishActiveTurn(id: turnID)
            }
        }
    }

    private func consumeSideChatTurn(_ handle: CodexTurnHandle) {
        sideChatStreamTask?.cancel()
        sideChatStreamTask = Task { [weak self] in
            guard let self else { return }
            let turnID = handle.id
            for await notification in handle.stream() {
                self.applySideChat(notification)
            }
            await MainActor.run {
                _ = self.finishSideChatTurn(id: turnID)
            }
        }
    }

    private func consumeGlobalNotifications(_ codex: Codex) {
        notificationTask?.cancel()
        notificationTask = Task { [weak self] in
            guard let self else { return }
            for await notification in codex.notifications() {
                if self.handleGlobalNotification(notification) {
                    continue
                } else if self.routeSubagentNotification(notification) {
                    continue
                } else if self.isActiveGoalTurnNotification(notification) {
                    self.apply(notification)
                } else if self.isActiveTurnCompletion(notification) {
                    self.apply(notification)
                }
            }
        }
    }

    @discardableResult
    private func handleGlobalNotification(_ notification: CodexNotification) -> Bool {
        switch notification.payload {
        case .known(let method, let params) where method == .threadStarted:
            applyThreadStartedMetadata(params)
            return true
        case .known(let method, _) where method == .skillsChanged:
            Task { await refreshSlashCommands(forceReload: true) }
            return true
        case .known(let method, let params) where method == .threadCompacted:
            handleThreadCompactedNotification(params)
            return true
        case .threadGoalUpdated(let payload):
            applyGoal(payload.goal, turnID: payload.turnId)
            return true
        case .threadGoalCleared(let payload):
            applyGoalCleared(threadID: payload.threadId)
            return true
        case .turnStarted(let payload) where shouldTrackGoalTurn(threadID: payload.threadId, turnID: payload.turn.id):
            activeGoalTurnID = payload.turn.id
            isSending = true
            apply(notification)
            return true
        case .known(let method, let params) where method == .mcpServerStartupStatusUpdated:
            applyMCPStartupStatus(params)
            return true
        case .unknown(let method, let params) where method == CodexAppServerNotificationMethod.threadStarted.rawValue:
            applyThreadStartedMetadata(params)
            return true
        case .unknown(let method, _) where method == CodexAppServerNotificationMethod.skillsChanged.rawValue:
            Task { await refreshSlashCommands(forceReload: true) }
            return true
        case .unknown(let method, let params) where method == CodexAppServerNotificationMethod.threadCompacted.rawValue:
            handleThreadCompactedNotification(params)
            return true
        case .known(let method, let params) where method == .threadGoalUpdated:
            if let payload = try? params.decode(ThreadGoalUpdatedNotification.self) {
                applyGoal(payload.goal, turnID: payload.turnId)
                return true
            }
        case .known(let method, let params) where method == .threadGoalCleared:
            applyGoalCleared(threadID: threadID(from: params))
            return true
        case .unknown(let method, let params) where method == CodexAppServerNotificationMethod.threadGoalUpdated.rawValue:
            if let payload = try? params.decode(ThreadGoalUpdatedNotification.self) {
                applyGoal(payload.goal, turnID: payload.turnId)
                return true
            }
        case .unknown(let method, let params) where method == CodexAppServerNotificationMethod.threadGoalCleared.rawValue:
            applyGoalCleared(threadID: threadID(from: params))
            return true
        case .unknown(let method, let params) where method == CodexAppServerNotificationMethod.mcpServerStartupStatusUpdated.rawValue:
            applyMCPStartupStatus(params)
            return true
        default:
            return false
        }
        return false
    }

    @discardableResult
    private func routeSubagentNotification(_ notification: CodexNotification) -> Bool {
        switch notification.payload {
        case .turnStarted(let payload):
            guard let threadID = payload.threadId,
                  let update = agentStateMapper.subagentTurnStarted(threadID: threadID) else {
                return false
            }
            syncAgentState()
            appendActivity(.turn, title: update.activityTitle, detail: update.activityDetail)
            return true
        case .itemStarted(let payload):
            guard let update = agentStateMapper.subagentItemStarted(threadID: payload.threadId, item: payload.item) else {
                return false
            }
            syncAgentState()
            appendActivity(.tool, title: update.activityTitle, detail: update.activityDetail)
            return true
        case .agentMessageDelta(let delta):
            guard agentStateMapper.subagentMessageDelta(delta.delta, threadID: delta.threadId, itemID: delta.itemId) else {
                return false
            }
            syncAgentState()
            return true
        case .itemCompleted(let payload):
            guard let update = agentStateMapper.subagentItemCompleted(threadID: payload.threadId, item: payload.item) else {
                return false
            }
            syncAgentState()
            appendActivity(.tool, title: update.activityTitle, detail: update.activityDetail)
            return true
        case .turnCompleted(let payload):
            guard let update = agentStateMapper.subagentTurnCompleted(threadID: payload.threadId, error: payload.turn.error?.message) else {
                return false
            }
            syncAgentState()
            appendActivity(.turn, title: update.activityTitle, detail: update.activityDetail)
            return true
        case .threadTokenUsageUpdated(let payload):
            return agentStateMapper.hasSubagentThread(id: payload.threadId)
        case .known(let method, let params):
            return routeKnownSubagentNotification(method, params: params)
        case .unknown(let method, let params):
            guard let known = CodexAppServerNotificationMethod(rawValue: method) else { return false }
            return routeKnownSubagentNotification(known, params: params)
        default:
            return false
        }
    }

    @discardableResult
    private func routeKnownSubagentNotification(_ method: CodexAppServerNotificationMethod, params: [String: CodexJSONValue]) -> Bool {
        switch method {
        case .itemCommandExecutionOutputDelta:
            guard let threadID = threadID(from: params),
                  let itemID = stringValue(params["itemId"]),
                  let delta = stringValue(params["delta"]),
                  agentStateMapper.subagentCommandOutputDelta(delta, threadID: threadID, itemID: itemID) else {
                return false
            }
            syncAgentState()
            return true
        case .itemCommandExecutionTerminalInteraction:
            guard let threadID = threadID(from: params),
                  let itemID = stringValue(params["itemId"]),
                  let stdin = stringValue(params["stdin"]),
                  !stdin.isEmpty,
                  agentStateMapper.subagentCommandOutputDelta("\n$ \(stdin)", threadID: threadID, itemID: itemID) else {
                return false
            }
            syncAgentState()
            return true
        case .itemFileChangeOutputDelta:
            guard let threadID = threadID(from: params),
                  let itemID = stringValue(params["itemId"]),
                  let delta = stringValue(params["delta"]),
                  agentStateMapper.subagentFileChangeOutputDelta(delta, threadID: threadID, itemID: itemID) else {
                return false
            }
            syncAgentState()
            return true
        case .itemFileChangePatchUpdated:
            guard let threadID = threadID(from: params),
                  let itemID = stringValue(params["itemId"]),
                  agentStateMapper.subagentFileChangePatchUpdated(threadID: threadID, itemID: itemID, raw: params) else {
                return false
            }
            syncAgentState()
            return true
        case .itemPlanDelta:
            guard let threadID = threadID(from: params),
                  let itemID = stringValue(params["itemId"]),
                  let delta = stringValue(params["delta"]),
                  agentStateMapper.subagentPlanDelta(delta, threadID: threadID, itemID: itemID) else {
                return false
            }
            syncAgentState()
            return true
        case .turnPlanUpdated:
            guard let threadID = threadID(from: params),
                  let turnID = turnID(from: params),
                  agentStateMapper.subagentPlanUpdated(
                    threadID: threadID,
                    itemID: stringValue(params["itemId"]) ?? "turn-plan-\(turnID)",
                    raw: params,
                    isStreaming: true
                  ) else {
                return false
            }
            syncAgentState()
            return true
        case .itemMCPToolCallProgress:
            guard let threadID = threadID(from: params),
                  let itemID = stringValue(params["itemId"]),
                  let message = stringValue(params["message"]),
                  agentStateMapper.subagentToolCallProgress(message, threadID: threadID, itemID: itemID) else {
                return false
            }
            syncAgentState()
            return true
        case .modelRerouted, .modelVerification, .warning, .guardianWarning, .deprecationNotice, .configWarning, .itemAutoApprovalReviewStarted, .itemAutoApprovalReviewCompleted:
            guard let threadID = threadID(from: params),
                  let update = agentStateMapper.subagentNotice(
                    method: method,
                    params: params,
                    threadID: threadID,
                    itemID: noticeItemID(method: method, params: params),
                    isStreaming: method == .itemAutoApprovalReviewStarted
                  ) else {
                return false
            }
            syncAgentState()
            appendActivity(.notice, title: update.activityTitle, detail: update.activityDetail)
            return true
        case .turnCompleted:
            guard let threadID = threadID(from: params),
                  let update = agentStateMapper.subagentTurnCompleted(threadID: threadID, error: turnErrorMessage(from: params)) else {
                return false
            }
            syncAgentState()
            appendActivity(.turn, title: update.activityTitle, detail: update.activityDetail)
            return true
        case .turnStarted:
            guard let threadID = threadID(from: params),
                  let update = agentStateMapper.subagentTurnStarted(threadID: threadID) else {
                return false
            }
            syncAgentState()
            appendActivity(.turn, title: update.activityTitle, detail: update.activityDetail)
            return true
        default:
            return false
        }
    }

    private func apply(_ notification: CodexNotification) {
        switch notification.payload {
        case .agentMessageDelta(let delta):
            if agentStateMapper.messageDelta(delta.delta, itemID: delta.itemId) {
                syncAgentState()
            } else {
                appendAssistantDelta(delta.delta, itemID: delta.itemId)
            }
        case .itemStarted(let payload):
            if payload.item.type == "commandExecution" {
                startCommandRun(payload.item)
            } else if payload.item.type == "fileChange" || payload.item.type == "patch" {
                startFileChange(payload.item)
            } else if payload.item.type == "mcpToolCall" || payload.item.type == "toolCall" {
                startToolCall(payload.item)
            } else if agentStateMapper.isSubagentItem(payload.item) {
                applyAgentItemStarted(payload.item)
            } else if payload.item.type == "agentMessage" || payload.item.type == "assistantMessage" {
                // Assistant message begins — handled by deltas.
            } else {
                appendActivity(.tool, title: "Working", detail: humanItemType(payload.item.type))
            }
        case .itemCompleted(let payload):
            applyCompletedItem(payload.item)
        case .threadTokenUsageUpdated(let payload):
            appendActivity(.token, title: "Token usage updated", detail: tokenSummary(payload.tokenUsage))
        case .turnStarted:
            currentPlan = []
            currentPlanExplanation = nil
            currentDiff = nil
            appendActivity(.turn, title: "Codex is working", detail: "Turn started")
        case .turnCompleted(let payload):
            finishActiveTurn(id: payload.turn.id)
        case .threadGoalUpdated(let payload):
            applyGoal(payload.goal, turnID: payload.turnId)
        case .threadGoalCleared(let payload):
            applyGoalCleared(threadID: payload.threadId)
        case .turnPlanUpdated(let payload):
            applyTurnPlan(payload)
        case .turnDiffUpdated(let payload):
            applyTurnDiff(payload)
        case .accountLoginCompleted:
            appendActivity(.login, title: "Login completed", detail: "Authentication updated")
        case .known(let method, let params):
            applyKnownNotification(method, params: params)
        case .unknown(let method, _):
            appendActivity(.notice, title: humanMethod(method), detail: "Notification")
        }
    }

    private func apply(_ event: CodexInteractivePromptEvent) {
        switch event {
        case .added(let prompt):
            if let index = interactivePrompts.firstIndex(where: { $0.id == prompt.id }) {
                interactivePrompts[index] = prompt
            } else {
                interactivePrompts.append(prompt)
            }
            appendActivity(.notice, title: "Input requested", detail: prompt.detail)
        case .resolved(let id):
            interactivePrompts.removeAll(where: { $0.id == id })
            appendActivity(.notice, title: "Input resolved", detail: id)
        }
    }

    private func applySideChat(_ notification: CodexNotification) {
        switch notification.payload {
        case .agentMessageDelta(let delta):
            appendSideChatAssistantDelta(delta.delta, itemID: delta.itemId)
        case .itemStarted(let payload):
            if payload.item.type == "commandExecution" {
                startSideChatCommandRun(payload.item)
            } else if payload.item.type == "fileChange" || payload.item.type == "patch" {
                startSideChatFileChange(payload.item)
            } else if payload.item.type == "mcpToolCall" || payload.item.type == "toolCall" {
                startSideChatToolCall(payload.item)
            } else if payload.item.type != "agentMessage", payload.item.type != "assistantMessage" {
                appendActivity(.tool, title: "Side chat working", detail: humanItemType(payload.item.type))
            }
        case .itemCompleted(let payload):
            applyCompletedSideChatItem(payload.item)
        case .threadTokenUsageUpdated:
            appendActivity(.token, title: "Side chat usage updated", detail: "Updated")
        case .turnStarted:
            appendActivity(.turn, title: "Side chat is working", detail: "Turn started")
        case .turnCompleted(let payload):
            finishSideChatTurn(id: payload.turn.id)
        case .known(let method, let params):
            applyKnownSideChatNotification(method, params: params)
        case .unknown(let method, let params):
            guard let known = CodexAppServerNotificationMethod(rawValue: method) else {
                appendActivity(.notice, title: humanMethod(method), detail: "Side chat notification")
                return
            }
            applyKnownSideChatNotification(known, params: params)
        default:
            break
        }
    }

    private func applyKnownSideChatNotification(_ method: CodexAppServerNotificationMethod, params: [String: CodexJSONValue]) {
        switch method {
        case .itemCommandExecutionOutputDelta:
            guard let itemID = stringValue(params["itemId"]), let delta = stringValue(params["delta"]) else {
                return
            }
            appendSideChatCommandOutput(delta, itemID: itemID)
        case .itemFileChangeOutputDelta:
            guard let itemID = stringValue(params["itemId"]), let delta = stringValue(params["delta"]) else {
                return
            }
            appendSideChatFileChangeOutput(delta, itemID: itemID)
        case .itemFileChangePatchUpdated:
            applySideChatFileChangePatchUpdated(params)
        case .itemPlanDelta:
            guard let itemID = stringValue(params["itemId"]), let delta = stringValue(params["delta"]) else {
                return
            }
            appendSideChatPlanDelta(delta, itemID: itemID)
        case .turnPlanUpdated:
            applySideChatTurnPlanUpdated(params)
        case .itemMCPToolCallProgress:
            guard let itemID = stringValue(params["itemId"]), let message = stringValue(params["message"]) else {
                return
            }
            appendSideChatToolCallProgress(message, itemID: itemID)
        case .modelRerouted, .modelVerification, .warning, .guardianWarning, .deprecationNotice, .configWarning, .itemAutoApprovalReviewStarted, .itemAutoApprovalReviewCompleted:
            applySideChatNotice(method, params: params)
        case .turnCompleted:
            finishSideChatTurn(id: turnID(from: params))
        default:
            break
        }
    }

    private func applyKnownNotification(_ method: CodexAppServerNotificationMethod, params: [String: CodexJSONValue]) {
        switch method {
        case .threadStarted:
            applyThreadStartedMetadata(params)
        case .threadCompacted:
            handleThreadCompactedNotification(params)
        case .mcpServerStartupStatusUpdated:
            applyMCPStartupStatus(params)
        case .turnCompleted:
            finishActiveTurn(id: turnID(from: params))
        case .itemCommandExecutionOutputDelta:
            guard let itemID = stringValue(params["itemId"]), let delta = stringValue(params["delta"]) else {
                return
            }
            appendCommandOutput(delta, itemID: itemID)
        case .itemCommandExecutionTerminalInteraction:
            guard let itemID = stringValue(params["itemId"]), let stdin = stringValue(params["stdin"]), !stdin.isEmpty else {
                return
            }
            appendCommandOutput("\n$ \(stdin)", itemID: itemID)
        case .itemFileChangeOutputDelta:
            guard let itemID = stringValue(params["itemId"]), let delta = stringValue(params["delta"]) else {
                return
            }
            appendFileChangeOutput(delta, itemID: itemID)
        case .itemFileChangePatchUpdated:
            applyFileChangePatchUpdated(params)
        case .turnDiffUpdated:
            applyTurnDiffUpdated(params)
        case .itemPlanDelta:
            guard let itemID = stringValue(params["itemId"]), let delta = stringValue(params["delta"]) else {
                return
            }
            appendPlanDelta(delta, itemID: itemID)
        case .turnPlanUpdated:
            applyTurnPlanUpdated(params)
        case .itemMCPToolCallProgress:
            guard let itemID = stringValue(params["itemId"]), let message = stringValue(params["message"]) else {
                return
            }
            appendToolCallProgress(message, itemID: itemID)
        case .modelRerouted, .modelVerification, .warning, .guardianWarning, .deprecationNotice, .configWarning, .itemAutoApprovalReviewStarted, .itemAutoApprovalReviewCompleted:
            applyNotice(method, params: params)
        default:
            appendActivity(.notice, title: humanMethod(method.rawValue), detail: "App-server notification")
        }
    }

    private func applyNotice(_ method: CodexAppServerNotificationMethod, params: [String: CodexJSONValue]) {
        let itemID = noticeItemID(method: method, params: params)
        guard let notice = Message.notice(
            itemID: itemID,
            method: method,
            raw: params,
            isStreaming: method == .itemAutoApprovalReviewStarted
        ) else {
            appendActivity(.notice, title: humanMethod(method.rawValue), detail: "App-server notification")
            return
        }

        upsertNotice(notice)
        appendActivity(.notice, title: notice.title, detail: notice.detail)
    }

    private func applySideChatNotice(_ method: CodexAppServerNotificationMethod, params: [String: CodexJSONValue]) {
        let itemID = noticeItemID(method: method, params: params)
        guard let notice = Message.notice(
            itemID: itemID,
            method: method,
            raw: params,
            isStreaming: method == .itemAutoApprovalReviewStarted
        ) else {
            return
        }

        upsertSideChatNotice(notice)
        appendActivity(.notice, title: "Side chat \(notice.title.lowercased())", detail: notice.detail)
    }

    private func upsertNotice(_ notice: Message.Notice) {
        if let messageID = noticeMessageIDsByItemID[notice.itemID],
           let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].notice = notice
            messages[index].text = notice.copyText
            messages[index].isStreaming = notice.isStreaming
            return
        }

        let message = Message(
            role: .notice,
            text: notice.copyText,
            isStreaming: notice.isStreaming,
            parseContent: false,
            notice: notice
        )
        noticeMessageIDsByItemID[notice.itemID] = message.id
        messages.append(message)
    }

    private func upsertSideChatNotice(_ notice: Message.Notice) {
        if let messageID = sideChatNoticeMessageIDsByItemID[notice.itemID],
           let index = locallyOpenedSideChat?.messages.firstIndex(where: { $0.id == messageID }) {
            updateLocalSideChat { sideChat in
                sideChat.messages[index].notice = notice
                sideChat.messages[index].text = notice.copyText
                sideChat.messages[index].isStreaming = notice.isStreaming
            }
            return
        }

        let message = Message(
            role: .notice,
            text: notice.copyText,
            isStreaming: notice.isStreaming,
            parseContent: false,
            notice: notice
        )
        sideChatNoticeMessageIDsByItemID[notice.itemID] = message.id
        updateLocalSideChat { $0.messages.append(message) }
    }

    private func noticeItemID(method: CodexAppServerNotificationMethod, params: [String: CodexJSONValue]) -> String {
        if let reviewID = stringValue(params["reviewId"]) {
            return "review-\(reviewID)"
        }
        if let itemID = stringValue(params["itemId"]) ?? stringValue(params["targetItemId"]) {
            return "\(method.rawValue)-\(itemID)"
        }
        let threadPart = threadID(from: params) ?? "global"
        let turnPart = turnID(from: params) ?? UUID().uuidString
        return "\(method.rawValue)-\(threadPart)-\(turnPart)-\(UUID().uuidString)"
    }

    @discardableResult
    private func finishActiveTurn(id turnID: String?) -> Bool {
        if let activeTurn {
            guard turnID == nil || activeTurn.id == turnID else { return false }
        } else if turnID != nil {
            return false
        }

        guard isSending || activeTurn != nil else { return false }
        finishMainStreamingToolMessages()
        isSending = false
        activeTurn = nil
        appendActivity(.turn, title: "Turn complete", detail: "Codex finished")
        Task { await refreshRecentChats() }
        flushQueuedFollowUps()
        return true
    }

    @discardableResult
    private func finishSideChatTurn(id turnID: String?) -> Bool {
        if let activeSideChatTurn {
            guard turnID == nil || activeSideChatTurn.id == turnID else { return false }
        } else if turnID != nil {
            return false
        }

        guard isSideChatSending || activeSideChatTurn != nil else { return false }
        finishSideChatStreamingMessages()
        isSideChatSending = false
        activeSideChatTurn = nil
        appendActivity(.turn, title: "Side chat complete", detail: "Focused branch finished")
        return true
    }

    private func isActiveTurnCompletion(_ notification: CodexNotification) -> Bool {
        switch notification.payload {
        case .turnCompleted(let payload):
            return activeTurn?.id == payload.turn.id
        case .known(let method, let params) where method == .turnCompleted:
            guard let turnID = turnID(from: params) else { return false }
            return activeTurn?.id == turnID
        case .unknown(let method, let params) where method == CodexAppServerNotificationMethod.turnCompleted.rawValue:
            guard let turnID = turnID(from: params) else { return false }
            return activeTurn?.id == turnID
        default:
            return false
        }
    }

    private func turnID(from params: [String: CodexJSONValue]) -> String? {
        if let direct = stringValue(params["turnId"]) { return direct }
        if let turn = dictionaryValue(params["turn"]), let nested = stringValue(turn["id"]) { return nested }
        return nil
    }

    private func threadID(from params: [String: CodexJSONValue]) -> String? {
        if let direct = stringValue(params["threadId"]) { return direct }
        if let thread = dictionaryValue(params["thread"]), let nested = stringValue(thread["id"]) { return nested }
        return nil
    }

    private func turnErrorMessage(from params: [String: CodexJSONValue]) -> String? {
        if let turn = dictionaryValue(params["turn"]) {
            if let error = dictionaryValue(turn["error"]) {
                return stringValue(error["message"]) ?? stringValue(error["raw"])
            }
            if let error = stringValue(turn["error"]) {
                return error
            }
        }
        if let error = dictionaryValue(params["error"]) {
            return stringValue(error["message"]) ?? stringValue(error["raw"])
        }
        return stringValue(params["error"])
    }

    // MARK: - Goal State

    private func applyGoal(_ goal: ThreadGoal, turnID: String?, shouldAnnounce: Bool = true) {
        let isUpdate = activeGoal != nil
        activeGoal = goal
        isGoalPursuitEnabled = true
        if let turnID { activeGoalTurnID = turnID }
        if goal.status != .active {
            activeGoalTurnID = nil
            isSending = false
        }
        if shouldAnnounce, isUpdate {
            let title = goal.status == .active ? "Goal progress" : "Goal \(goal.status.rawValue)"
            appendActivity(.notice, title: title, detail: goalProgressSummary(goal))
        }
    }

    private func applyGoalCleared(threadID: String?) {
        guard threadID == nil || threadID == currentThreadID else { return }
        guard activeGoal != nil else { return }
        clearGoalState()
        appendActivity(.notice, title: "Goal cleared", detail: "Thread goal removed")
    }

    private func clearGoalState() {
        activeGoal = nil
        activeGoalTurnID = nil
        isGoalPursuitEnabled = false
    }

    private func goalProgressSummary(_ goal: ThreadGoal) -> String {
        var parts = [goal.objective]
        if let budget = goal.tokenBudget, budget > 0 {
            parts.append("\(goal.tokensUsed)/\(budget) tokens")
        } else if goal.tokensUsed > 0 {
            parts.append("\(goal.tokensUsed) tokens")
        }
        if goal.timeUsedSeconds > 0 {
            parts.append("\(goal.timeUsedSeconds)s elapsed")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Turn Plan & Diff

    private func applyTurnPlan(_ payload: TurnPlanUpdatedNotification) {
        currentPlan = payload.plan
        currentPlanExplanation = payload.explanation
        let done = payload.plan.filter { $0.status == .completed }.count
        let active = payload.plan.first(where: { $0.status == .inProgress })?.step
        appendActivity(.turn, title: "Plan updated (\(done)/\(payload.plan.count))", detail: active ?? payload.explanation ?? "Plan revised")
    }

    private func applyTurnDiff(_ payload: TurnDiffUpdatedNotification) {
        currentDiff = payload.diff.isEmpty ? nil : payload.diff
        if let currentDiff {
            let fileCount = currentDiff.components(separatedBy: "diff --git").count - 1
            appendActivity(.tool, title: "Diff updated", detail: fileCount > 0 ? "\(fileCount) file(s) changed" : "Working tree changed")
        }
    }

    private func shouldTrackGoalTurn(threadID: String?, turnID: String) -> Bool {
        guard activeGoal != nil, activeGoalTurnID == nil else { return false }
        guard let threadID else { return false }
        return threadID == currentThreadID
    }

    private func isActiveGoalTurnNotification(_ notification: CodexNotification) -> Bool {
        guard let activeGoalTurnID else { return false }
        switch notification.payload {
        case .itemStarted(let payload):
            return payload.turnId == activeGoalTurnID
        case .itemCompleted(let payload):
            return payload.turnId == activeGoalTurnID
        case .agentMessageDelta(let payload):
            return payload.turnId == activeGoalTurnID
        case .threadTokenUsageUpdated(let payload):
            return payload.turnId == activeGoalTurnID
        case .threadGoalUpdated(let payload):
            return payload.turnId == activeGoalTurnID
        case .turnStarted(let payload):
            return payload.turn.id == activeGoalTurnID
        case .turnCompleted(let payload):
            return payload.turn.id == activeGoalTurnID
        case .known(_, let params), .unknown(_, let params):
            return turnID(from: params) == activeGoalTurnID
        default:
            return false
        }
    }

    private func handleThreadCompactedNotification(_ params: [String: CodexJSONValue]) {
        let compactedThreadID = threadID(from: params)
        guard compactedThreadID == nil || compactedThreadID == thread?.id else { return }
        appendActivity(.notice, title: "Context compacted", detail: compactedThreadID ?? currentThreadID ?? "Current chat")
        Task { await refreshRecentChats() }
    }

    private func applyMCPStartupStatus(_ params: [String: CodexJSONValue]) {
        guard let name = stringValue(params["name"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              let status = stringValue(params["status"]) else {
            return
        }

        let error = stringValue(params["error"])
        if let index = mcpServers.firstIndex(where: { $0.name == name }) {
            mcpServers[index] = mcpServers[index].applyingStartupStatus(status, error: error)
        } else {
            mcpServers.append(CodexMCPServerStatus(name: name, startupStatus: status, error: error))
        }
        appendActivity(.notice, title: "MCP \(status)", detail: error ?? name)
    }

    private func applyThreadStartedMetadata(_ params: [String: CodexJSONValue]) {
        guard let thread = dictionaryValue(params["thread"]),
              stringValue(thread["parentThreadId"]) != nil,
              let threadID = stringValue(thread["id"]) else {
            return
        }

        let name = stringValue(thread["agentNickname"])
            ?? stringValue(thread["name"])
        let role = stringValue(thread["agentRole"])
        if agentStateMapper.updateSubagentMetadata(id: threadID, name: name, role: role) {
            syncAgentState()
        }
    }

    private func applyCompletedItem(_ item: ThreadItem) {
        switch item.type {
        case "agentMessage", "assistantMessage":
            guard let text = item.text, !text.isEmpty else { return }
            let phase = item.phase ?? stringValue(item.raw["phase"])
            if let messageID = assistantMessageIDsByItemID[item.id], let index = messages.firstIndex(where: { $0.id == messageID }) {
                messages[index].setText(text, parseContent: true)
                messages[index].isStreaming = false
                messages[index].detail = phase
            } else {
                let message = Message(role: .assistant, text: text, detail: phase)
                assistantMessageIDsByItemID[item.id] = message.id
                messages.append(message)
            }
            if agentStateMapper.assistantMessageCompleted(text) {
                syncAgentState()
            }
            appendActivity(.tool, title: "Codex replied", detail: previewText(text))
        case "userMessage":
            break
        case "commandExecution":
            finalizeCommandRun(item)
        case "fileChange", "patch":
            finalizeFileChange(item)
        case "mcpToolCall", "toolCall":
            finalizeToolCall(item)
        case _ where agentStateMapper.isSubagentItem(item):
            applyAgentItemCompleted(item)
        default:
            appendActivity(.tool, title: humanItemType(item.type), detail: "Completed")
        }
    }

    private func appendAssistantDelta(_ text: String, itemID: String) {
        if let messageID = assistantMessageIDsByItemID[itemID], let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].appendStreamingText(text)
            messages[index].isStreaming = true
            return
        }

        var message = Message(role: .assistant, text: text, isStreaming: true, parseContent: false)
        message.detail = nil
        assistantMessageIDsByItemID[itemID] = message.id
        messages.append(message)
    }

    private func appendCommandOutput(_ delta: String, itemID: String) {
        if let messageID = commandMessageIDsByItemID[itemID], let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].commandRun?.output.append(delta)
            messages[index].commandRun?.isStreaming = true
            messages[index].isStreaming = true
            messages[index].text = messages[index].commandRun?.output ?? ""
            return
        }

        let run = Message.CommandRun(
            itemID: itemID,
            command: "Running command",
            cwd: nil,
            output: delta,
            status: "active",
            exitCode: nil,
            isStreaming: true
        )
        let message = Message(role: .terminal, text: delta, isStreaming: true, parseContent: false, commandRun: run)
        commandMessageIDsByItemID[itemID] = message.id
        messages.append(message)
    }

    private func startCommandRun(_ item: ThreadItem) {
        if commandMessageIDsByItemID[item.id] != nil { return }
        let run = Message.CommandRun(
            itemID: item.id,
            command: stringValue(item.raw["command"]) ?? "Running command",
            cwd: stringValue(item.raw["cwd"]),
            output: "",
            status: stringValue(item.raw["status"]) ?? "active",
            exitCode: nil,
            isStreaming: true
        )
        let message = Message(role: .terminal, text: "", isStreaming: true, parseContent: false, commandRun: run)
        commandMessageIDsByItemID[item.id] = message.id
        messages.append(message)
        appendActivity(.tool, title: "Ran a command", detail: run.command)
    }

    private func finalizeCommandRun(_ item: ThreadItem) {
        let command = stringValue(item.raw["command"]) ?? "Command"
        let output = stringValue(item.raw["aggregatedOutput"])
            ?? stringValue(item.raw["output"])
            ?? stringValue(item.raw["stdout"])
            ?? ""
        let status = stringValue(item.raw["status"]) ?? "completed"
        let run = Message.CommandRun(
            itemID: item.id,
            command: command,
            cwd: stringValue(item.raw["cwd"]),
            output: output,
            status: status,
            exitCode: intValue(item.raw["exitCode"]),
            isStreaming: status == "active" || status == "inProgress"
        )

        if let messageID = commandMessageIDsByItemID[item.id], let index = messages.firstIndex(where: { $0.id == messageID }) {
            var finalRun = run
            if finalRun.output.isEmpty {
                finalRun.output = messages[index].commandRun?.output ?? ""
            }
            messages[index].commandRun = finalRun
            messages[index].text = finalRun.output
            messages[index].isStreaming = finalRun.isStreaming
            return
        }

        let message = Message(role: .terminal, text: output, isStreaming: run.isStreaming, parseContent: false, commandRun: run)
        commandMessageIDsByItemID[item.id] = message.id
        messages.append(message)
    }

    private func startFileChange(_ item: ThreadItem) {
        if fileChangeMessageIDsByItemID[item.id] != nil { return }
        let change = fileChange(from: item, fallbackStatus: "active")
            ?? Message.fileChange(
                itemID: item.id,
                path: stringValue(item.raw["path"]),
                diff: "",
                kind: stringValue(item.raw["kind"]) ?? "update",
                status: "active",
                isStreaming: true
            )
        let message = Message(
            role: .fileChange,
            text: change.diff,
            isStreaming: change.isStreaming,
            parseContent: false,
            fileChange: change
        )
        fileChangeMessageIDsByItemID[item.id] = message.id
        messages.append(message)
        appendActivity(.tool, title: "Editing files", detail: change.displayPath)
    }

    private func appendFileChangeOutput(_ delta: String, itemID: String) {
        if let messageID = fileChangeMessageIDsByItemID[itemID], let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].fileChange?.output.append(delta)
            messages[index].fileChange?.isStreaming = true
            messages[index].isStreaming = true
            return
        }

        var change = Message.fileChange(itemID: itemID, path: nil, diff: "", output: delta, status: "active", isStreaming: true)
        change.output = delta
        let message = Message(role: .fileChange, text: delta, isStreaming: true, parseContent: false, fileChange: change)
        fileChangeMessageIDsByItemID[itemID] = message.id
        messages.append(message)
    }

    private func applyFileChangePatchUpdated(_ params: [String: CodexJSONValue]) {
        guard let itemID = stringValue(params["itemId"]) else { return }
        let change = fileChange(from: params, itemID: itemID, fallbackStatus: "active")
        upsertFileChange(change)
        appendActivity(.tool, title: "Patch updated", detail: change.displayPath)
    }

    private func applyTurnDiffUpdated(_ params: [String: CodexJSONValue]) {
        guard let turnID = turnID(from: params),
              let diff = stringValue(params["diff"]),
              !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let change = Message.fileChange(
            itemID: "turn-diff-\(turnID)",
            path: nil,
            diff: diff,
            kind: "turn diff",
            status: "active",
            isStreaming: activeTurn?.id == turnID
        )
        upsertFileChange(change)
    }

    private func finalizeFileChange(_ item: ThreadItem) {
        var change = fileChange(from: item, fallbackStatus: "completed")
            ?? Message.fileChange(
                itemID: item.id,
                path: stringValue(item.raw["path"]),
                diff: stringValue(item.raw["patch"]) ?? stringValue(item.raw["diff"]) ?? "",
                kind: stringValue(item.raw["kind"]) ?? "update",
                status: stringValue(item.raw["status"]) ?? "completed",
                isStreaming: false
            )
        change.isStreaming = false
        if change.status == "active" || change.status == "running" || change.status == "inProgress" {
            change.status = "completed"
        }
        upsertFileChange(change)
        appendActivity(.tool, title: "File change complete", detail: change.displayPath)
    }

    private func upsertFileChange(_ change: Message.FileChange) {
        if let messageID = fileChangeMessageIDsByItemID[change.itemID], let index = messages.firstIndex(where: { $0.id == messageID }) {
            var merged = change
            if merged.diff.isEmpty {
                merged.diff = messages[index].fileChange?.diff ?? ""
            }
            if merged.output.isEmpty {
                merged.output = messages[index].fileChange?.output ?? ""
            }
            messages[index].fileChange = merged
            messages[index].text = merged.diff.isEmpty ? merged.output : merged.diff
            messages[index].isStreaming = merged.isStreaming
            return
        }

        let message = Message(
            role: .fileChange,
            text: change.diff.isEmpty ? change.output : change.diff,
            isStreaming: change.isStreaming,
            parseContent: false,
            fileChange: change
        )
        fileChangeMessageIDsByItemID[change.itemID] = message.id
        messages.append(message)
    }

    private func appendPlanDelta(_ delta: String, itemID: String) {
        if let messageID = planMessageIDsByItemID[itemID], let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].planUpdate?.text.append(delta)
            messages[index].planUpdate?.isStreaming = true
            messages[index].text = messages[index].planUpdate?.copyText ?? messages[index].text
            messages[index].isStreaming = true
            return
        }

        let plan = Message.planUpdate(itemID: itemID, text: delta, isStreaming: true)
        let message = Message(role: .plan, text: plan.copyText, isStreaming: true, parseContent: false, planUpdate: plan)
        planMessageIDsByItemID[itemID] = message.id
        messages.append(message)
    }

    private func applyTurnPlanUpdated(_ params: [String: CodexJSONValue]) {
        guard let turnID = turnID(from: params) else { return }
        let itemID = stringValue(params["itemId"]) ?? "turn-plan-\(turnID)"
        guard var plan = planUpdate(from: params, itemID: itemID, isStreaming: activeTurn?.id == turnID) else {
            return
        }
        if activeTurn?.id != turnID {
            plan.isStreaming = false
        }
        upsertPlan(plan)
        appendActivity(.tool, title: "Plan updated", detail: plan.summary)
    }

    private func upsertPlan(_ plan: Message.PlanUpdate) {
        if let messageID = planMessageIDsByItemID[plan.itemID], let index = messages.firstIndex(where: { $0.id == messageID }) {
            var merged = plan
            if merged.text.isEmpty {
                merged.text = messages[index].planUpdate?.text ?? ""
            }
            messages[index].planUpdate = merged
            messages[index].text = merged.copyText
            messages[index].isStreaming = merged.isStreaming
            return
        }

        let message = Message(role: .plan, text: plan.copyText, isStreaming: plan.isStreaming, parseContent: false, planUpdate: plan)
        planMessageIDsByItemID[plan.itemID] = message.id
        messages.append(message)
    }

    private func startToolCall(_ item: ThreadItem) {
        if toolCallMessageIDsByItemID[item.id] != nil { return }
        let toolCall = toolCall(from: item, fallbackStatus: "inProgress")
        let message = Message(role: .tool, text: toolCall.copyText, isStreaming: toolCall.isStreaming, parseContent: false, toolCall: toolCall)
        toolCallMessageIDsByItemID[item.id] = message.id
        messages.append(message)
        appendActivity(.tool, title: "Calling tool", detail: toolCall.displayName)
    }

    private func appendToolCallProgress(_ progress: String, itemID: String) {
        if let messageID = toolCallMessageIDsByItemID[itemID], let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].toolCall?.progress.append(progress)
            messages[index].toolCall?.isStreaming = true
            messages[index].isStreaming = true
            messages[index].text = messages[index].toolCall?.copyText ?? ""
            return
        }

        let toolCall = Message.toolCall(itemID: itemID, server: nil, tool: "Tool", progress: [progress], isStreaming: true)
        let message = Message(role: .tool, text: toolCall.copyText, isStreaming: true, parseContent: false, toolCall: toolCall)
        toolCallMessageIDsByItemID[itemID] = message.id
        messages.append(message)
    }

    private func finalizeToolCall(_ item: ThreadItem) {
        var toolCall = toolCall(from: item, fallbackStatus: "completed")
        toolCall.isStreaming = false
        upsertToolCall(toolCall)
        appendActivity(.tool, title: toolCall.error == nil ? "Tool complete" : "Tool failed", detail: toolCall.displayName)
    }

    private func upsertToolCall(_ toolCall: Message.ToolCall) {
        if let messageID = toolCallMessageIDsByItemID[toolCall.itemID], let index = messages.firstIndex(where: { $0.id == messageID }) {
            var merged = toolCall
            if merged.progress.isEmpty {
                merged.progress = messages[index].toolCall?.progress ?? []
            }
            if merged.arguments.isEmpty {
                merged.arguments = messages[index].toolCall?.arguments ?? ""
            }
            if merged.result.isEmpty {
                merged.result = messages[index].toolCall?.result ?? ""
            }
            messages[index].toolCall = merged
            messages[index].text = merged.copyText
            messages[index].isStreaming = merged.isStreaming
            return
        }

        let message = Message(role: .tool, text: toolCall.copyText, isStreaming: toolCall.isStreaming, parseContent: false, toolCall: toolCall)
        toolCallMessageIDsByItemID[toolCall.itemID] = message.id
        messages.append(message)
    }

    private func applyCompletedSideChatItem(_ item: ThreadItem) {
        switch item.type {
        case "agentMessage", "assistantMessage":
            guard let text = item.text, !text.isEmpty else { return }
            if let messageID = sideChatAssistantMessageIDsByItemID[item.id],
               let index = locallyOpenedSideChat?.messages.firstIndex(where: { $0.id == messageID }) {
                updateLocalSideChat { sideChat in
                    sideChat.messages[index].setText(text, parseContent: true)
                    sideChat.messages[index].isStreaming = false
                }
            } else {
                let message = Message(role: .assistant, text: text)
                sideChatAssistantMessageIDsByItemID[item.id] = message.id
                updateLocalSideChat { $0.messages.append(message) }
            }
            appendActivity(.tool, title: "Side chat replied", detail: previewText(text))
        case "userMessage":
            break
        case "commandExecution":
            finalizeSideChatCommandRun(item)
        case "fileChange", "patch":
            finalizeSideChatFileChange(item)
        case "mcpToolCall", "toolCall":
            finalizeSideChatToolCall(item)
        default:
            appendActivity(.tool, title: "Side chat \(humanItemType(item.type))", detail: "Completed")
        }
    }

    private func appendLocalSideChatMessage(_ role: Message.Role, _ text: String, detail: String? = nil) {
        updateLocalSideChat { sideChat in
            sideChat.messages.append(Message(role: role, text: text, detail: detail))
        }
    }

    private func appendSideChatAssistantDelta(_ text: String, itemID: String) {
        if let messageID = sideChatAssistantMessageIDsByItemID[itemID],
           let index = locallyOpenedSideChat?.messages.firstIndex(where: { $0.id == messageID }) {
            updateLocalSideChat { sideChat in
                sideChat.messages[index].appendStreamingText(text)
                sideChat.messages[index].isStreaming = true
            }
            return
        }

        var message = Message(role: .assistant, text: text, isStreaming: true, parseContent: false)
        message.detail = nil
        sideChatAssistantMessageIDsByItemID[itemID] = message.id
        updateLocalSideChat { $0.messages.append(message) }
    }

    private func startSideChatCommandRun(_ item: ThreadItem) {
        if sideChatCommandMessageIDsByItemID[item.id] != nil { return }
        let run = Message.CommandRun(
            itemID: item.id,
            command: stringValue(item.raw["command"]) ?? "Running command",
            cwd: stringValue(item.raw["cwd"]),
            output: "",
            status: stringValue(item.raw["status"]) ?? "active",
            exitCode: nil,
            isStreaming: true
        )
        let message = Message(role: .terminal, text: "", isStreaming: true, parseContent: false, commandRun: run)
        sideChatCommandMessageIDsByItemID[item.id] = message.id
        updateLocalSideChat { $0.messages.append(message) }
        appendActivity(.tool, title: "Side chat ran command", detail: run.command)
    }

    private func appendSideChatCommandOutput(_ delta: String, itemID: String) {
        if let messageID = sideChatCommandMessageIDsByItemID[itemID],
           let index = locallyOpenedSideChat?.messages.firstIndex(where: { $0.id == messageID }) {
            updateLocalSideChat { sideChat in
                sideChat.messages[index].commandRun?.output.append(delta)
                sideChat.messages[index].commandRun?.isStreaming = true
                sideChat.messages[index].isStreaming = true
                sideChat.messages[index].text = sideChat.messages[index].commandRun?.output ?? ""
            }
            return
        }

        let run = Message.CommandRun(
            itemID: itemID,
            command: "Running command",
            cwd: nil,
            output: delta,
            status: "active",
            exitCode: nil,
            isStreaming: true
        )
        let message = Message(role: .terminal, text: delta, isStreaming: true, parseContent: false, commandRun: run)
        sideChatCommandMessageIDsByItemID[itemID] = message.id
        updateLocalSideChat { $0.messages.append(message) }
    }

    private func finalizeSideChatCommandRun(_ item: ThreadItem) {
        let command = stringValue(item.raw["command"]) ?? "Command"
        let output = stringValue(item.raw["aggregatedOutput"])
            ?? stringValue(item.raw["output"])
            ?? stringValue(item.raw["stdout"])
            ?? ""
        let status = stringValue(item.raw["status"]) ?? "completed"
        let run = Message.CommandRun(
            itemID: item.id,
            command: command,
            cwd: stringValue(item.raw["cwd"]),
            output: output,
            status: status,
            exitCode: intValue(item.raw["exitCode"]),
            isStreaming: status == "active" || status == "inProgress"
        )

        if let messageID = sideChatCommandMessageIDsByItemID[item.id],
           let index = locallyOpenedSideChat?.messages.firstIndex(where: { $0.id == messageID }) {
            updateLocalSideChat { sideChat in
                var finalRun = run
                if finalRun.output.isEmpty {
                    finalRun.output = sideChat.messages[index].commandRun?.output ?? ""
                }
                sideChat.messages[index].commandRun = finalRun
                sideChat.messages[index].text = finalRun.output
                sideChat.messages[index].isStreaming = finalRun.isStreaming
            }
            return
        }

        let message = Message(role: .terminal, text: output, isStreaming: run.isStreaming, parseContent: false, commandRun: run)
        sideChatCommandMessageIDsByItemID[item.id] = message.id
        updateLocalSideChat { $0.messages.append(message) }
    }

    private func startSideChatFileChange(_ item: ThreadItem) {
        if sideChatFileChangeMessageIDsByItemID[item.id] != nil { return }
        let change = fileChange(from: item, fallbackStatus: "active")
            ?? Message.fileChange(
                itemID: item.id,
                path: stringValue(item.raw["path"]),
                diff: "",
                kind: stringValue(item.raw["kind"]) ?? "update",
                status: "active",
                isStreaming: true
            )
        let message = Message(role: .fileChange, text: change.diff, isStreaming: change.isStreaming, parseContent: false, fileChange: change)
        sideChatFileChangeMessageIDsByItemID[item.id] = message.id
        updateLocalSideChat { $0.messages.append(message) }
        appendActivity(.tool, title: "Side chat editing files", detail: change.displayPath)
    }

    private func appendSideChatFileChangeOutput(_ delta: String, itemID: String) {
        if let messageID = sideChatFileChangeMessageIDsByItemID[itemID],
           let index = locallyOpenedSideChat?.messages.firstIndex(where: { $0.id == messageID }) {
            updateLocalSideChat { sideChat in
                sideChat.messages[index].fileChange?.output.append(delta)
                sideChat.messages[index].fileChange?.isStreaming = true
                sideChat.messages[index].isStreaming = true
            }
            return
        }

        var change = Message.fileChange(itemID: itemID, path: nil, diff: "", output: delta, status: "active", isStreaming: true)
        change.output = delta
        let message = Message(role: .fileChange, text: delta, isStreaming: true, parseContent: false, fileChange: change)
        sideChatFileChangeMessageIDsByItemID[itemID] = message.id
        updateLocalSideChat { $0.messages.append(message) }
    }

    private func applySideChatFileChangePatchUpdated(_ params: [String: CodexJSONValue]) {
        guard let itemID = stringValue(params["itemId"]) else { return }
        let change = fileChange(from: params, itemID: itemID, fallbackStatus: "active")
        upsertSideChatFileChange(change)
        appendActivity(.tool, title: "Side chat patch updated", detail: change.displayPath)
    }

    private func finalizeSideChatFileChange(_ item: ThreadItem) {
        var change = fileChange(from: item, fallbackStatus: "completed")
            ?? Message.fileChange(
                itemID: item.id,
                path: stringValue(item.raw["path"]),
                diff: stringValue(item.raw["patch"]) ?? stringValue(item.raw["diff"]) ?? "",
                kind: stringValue(item.raw["kind"]) ?? "update",
                status: stringValue(item.raw["status"]) ?? "completed",
                isStreaming: false
            )
        change.isStreaming = false
        if change.status == "active" || change.status == "running" || change.status == "inProgress" {
            change.status = "completed"
        }
        upsertSideChatFileChange(change)
        appendActivity(.tool, title: "Side chat file change complete", detail: change.displayPath)
    }

    private func upsertSideChatFileChange(_ change: Message.FileChange) {
        if let messageID = sideChatFileChangeMessageIDsByItemID[change.itemID],
           let index = locallyOpenedSideChat?.messages.firstIndex(where: { $0.id == messageID }) {
            updateLocalSideChat { sideChat in
                var merged = change
                if merged.diff.isEmpty {
                    merged.diff = sideChat.messages[index].fileChange?.diff ?? ""
                }
                if merged.output.isEmpty {
                    merged.output = sideChat.messages[index].fileChange?.output ?? ""
                }
                sideChat.messages[index].fileChange = merged
                sideChat.messages[index].text = merged.diff.isEmpty ? merged.output : merged.diff
                sideChat.messages[index].isStreaming = merged.isStreaming
            }
            return
        }

        let message = Message(
            role: .fileChange,
            text: change.diff.isEmpty ? change.output : change.diff,
            isStreaming: change.isStreaming,
            parseContent: false,
            fileChange: change
        )
        sideChatFileChangeMessageIDsByItemID[change.itemID] = message.id
        updateLocalSideChat { $0.messages.append(message) }
    }

    private func appendSideChatPlanDelta(_ delta: String, itemID: String) {
        if let messageID = sideChatPlanMessageIDsByItemID[itemID],
           let index = locallyOpenedSideChat?.messages.firstIndex(where: { $0.id == messageID }) {
            updateLocalSideChat { sideChat in
                sideChat.messages[index].planUpdate?.text.append(delta)
                sideChat.messages[index].planUpdate?.isStreaming = true
                sideChat.messages[index].text = sideChat.messages[index].planUpdate?.copyText ?? sideChat.messages[index].text
                sideChat.messages[index].isStreaming = true
            }
            return
        }

        let plan = Message.planUpdate(itemID: itemID, text: delta, isStreaming: true)
        let message = Message(role: .plan, text: plan.copyText, isStreaming: true, parseContent: false, planUpdate: plan)
        sideChatPlanMessageIDsByItemID[itemID] = message.id
        updateLocalSideChat { $0.messages.append(message) }
    }

    private func applySideChatTurnPlanUpdated(_ params: [String: CodexJSONValue]) {
        guard let turnID = turnID(from: params) else { return }
        let itemID = stringValue(params["itemId"]) ?? "turn-plan-\(turnID)"
        guard var plan = planUpdate(from: params, itemID: itemID, isStreaming: activeSideChatTurn?.id == turnID) else {
            return
        }
        if activeSideChatTurn?.id != turnID {
            plan.isStreaming = false
        }
        upsertSideChatPlan(plan)
        appendActivity(.tool, title: "Side chat plan updated", detail: plan.summary)
    }

    private func upsertSideChatPlan(_ plan: Message.PlanUpdate) {
        if let messageID = sideChatPlanMessageIDsByItemID[plan.itemID],
           let index = locallyOpenedSideChat?.messages.firstIndex(where: { $0.id == messageID }) {
            updateLocalSideChat { sideChat in
                var merged = plan
                if merged.text.isEmpty {
                    merged.text = sideChat.messages[index].planUpdate?.text ?? ""
                }
                sideChat.messages[index].planUpdate = merged
                sideChat.messages[index].text = merged.copyText
                sideChat.messages[index].isStreaming = merged.isStreaming
            }
            return
        }

        let message = Message(role: .plan, text: plan.copyText, isStreaming: plan.isStreaming, parseContent: false, planUpdate: plan)
        sideChatPlanMessageIDsByItemID[plan.itemID] = message.id
        updateLocalSideChat { $0.messages.append(message) }
    }

    private func startSideChatToolCall(_ item: ThreadItem) {
        if sideChatToolCallMessageIDsByItemID[item.id] != nil { return }
        let toolCall = toolCall(from: item, fallbackStatus: "inProgress")
        let message = Message(role: .tool, text: toolCall.copyText, isStreaming: toolCall.isStreaming, parseContent: false, toolCall: toolCall)
        sideChatToolCallMessageIDsByItemID[item.id] = message.id
        updateLocalSideChat { $0.messages.append(message) }
        appendActivity(.tool, title: "Side chat calling tool", detail: toolCall.displayName)
    }

    private func appendSideChatToolCallProgress(_ progress: String, itemID: String) {
        if let messageID = sideChatToolCallMessageIDsByItemID[itemID],
           let index = locallyOpenedSideChat?.messages.firstIndex(where: { $0.id == messageID }) {
            updateLocalSideChat { sideChat in
                sideChat.messages[index].toolCall?.progress.append(progress)
                sideChat.messages[index].toolCall?.isStreaming = true
                sideChat.messages[index].isStreaming = true
                sideChat.messages[index].text = sideChat.messages[index].toolCall?.copyText ?? ""
            }
            return
        }

        let toolCall = Message.toolCall(itemID: itemID, server: nil, tool: "Tool", progress: [progress], isStreaming: true)
        let message = Message(role: .tool, text: toolCall.copyText, isStreaming: true, parseContent: false, toolCall: toolCall)
        sideChatToolCallMessageIDsByItemID[itemID] = message.id
        updateLocalSideChat { $0.messages.append(message) }
    }

    private func finalizeSideChatToolCall(_ item: ThreadItem) {
        var toolCall = toolCall(from: item, fallbackStatus: "completed")
        toolCall.isStreaming = false
        upsertSideChatToolCall(toolCall)
        appendActivity(.tool, title: toolCall.error == nil ? "Side chat tool complete" : "Side chat tool failed", detail: toolCall.displayName)
    }

    private func upsertSideChatToolCall(_ toolCall: Message.ToolCall) {
        if let messageID = sideChatToolCallMessageIDsByItemID[toolCall.itemID],
           let index = locallyOpenedSideChat?.messages.firstIndex(where: { $0.id == messageID }) {
            updateLocalSideChat { sideChat in
                var merged = toolCall
                if merged.progress.isEmpty {
                    merged.progress = sideChat.messages[index].toolCall?.progress ?? []
                }
                if merged.arguments.isEmpty {
                    merged.arguments = sideChat.messages[index].toolCall?.arguments ?? ""
                }
                if merged.result.isEmpty {
                    merged.result = sideChat.messages[index].toolCall?.result ?? ""
                }
                sideChat.messages[index].toolCall = merged
                sideChat.messages[index].text = merged.copyText
                sideChat.messages[index].isStreaming = merged.isStreaming
            }
            return
        }

        let message = Message(role: .tool, text: toolCall.copyText, isStreaming: toolCall.isStreaming, parseContent: false, toolCall: toolCall)
        sideChatToolCallMessageIDsByItemID[toolCall.itemID] = message.id
        updateLocalSideChat { $0.messages.append(message) }
    }

    private func finishSideChatStreamingMessages() {
        updateLocalSideChat { sideChat in
            for index in sideChat.messages.indices where sideChat.messages[index].isStreaming {
                sideChat.messages[index].isStreaming = false
                if sideChat.messages[index].role == .assistant {
                    sideChat.messages[index].setText(sideChat.messages[index].text, parseContent: true)
                }
                if sideChat.messages[index].commandRun != nil {
                    sideChat.messages[index].commandRun?.isStreaming = false
                }
                if sideChat.messages[index].fileChange != nil {
                    sideChat.messages[index].fileChange?.isStreaming = false
                }
                if sideChat.messages[index].planUpdate != nil {
                    sideChat.messages[index].planUpdate?.isStreaming = false
                }
                if sideChat.messages[index].toolCall != nil {
                    sideChat.messages[index].toolCall?.isStreaming = false
                }
                if sideChat.messages[index].notice != nil {
                    sideChat.messages[index].notice?.isStreaming = false
                }
            }
        }
    }

    private func updateLocalSideChat(_ update: (inout CodexSideChatState) -> Void) {
        if locallyOpenedSideChat == nil {
            locallyOpenedSideChat = CodexSideChatState(createdAt: Date())
        }
        guard var sideChat = locallyOpenedSideChat else { return }
        update(&sideChat)
        locallyOpenedSideChat = sideChat
        syncAgentState()
    }

    private func applyAgentItemStarted(_ item: ThreadItem) {
        guard let update = agentStateMapper.itemStarted(item) else { return }
        syncAgentState()
        appendActivity(.tool, title: update.activityTitle, detail: update.activityDetail)
    }

    private func applyAgentItemCompleted(_ item: ThreadItem) {
        guard let update = agentStateMapper.itemCompleted(item) else { return }
        syncAgentState()
        appendActivity(.tool, title: update.activityTitle, detail: update.activityDetail)
    }

    private func syncAgentState() {
        lifecycleEvents = agentStateMapper.lifecycleEvents
        sideChat = locallyOpenedSideChat ?? agentStateMapper.sideChat
        subagents = agentStateMapper.subagents
    }

    private func fileChange(from item: ThreadItem, fallbackStatus: String) -> Message.FileChange? {
        fileChange(from: item.raw, itemID: item.id, fallbackStatus: fallbackStatus)
    }

    private func fileChange(
        from params: [String: CodexJSONValue],
        itemID: String,
        fallbackStatus: String
    ) -> Message.FileChange {
        var raw = params
        if raw["status"] == nil {
            raw["status"] = .string(fallbackStatus)
        }
        return Message.fileChange(itemID: itemID, raw: raw, fallbackStatus: fallbackStatus)
            ?? Message.fileChange(
                itemID: itemID,
                path: stringValue(raw["path"]),
                diff: stringValue(raw["diff"]) ?? stringValue(raw["patch"]) ?? "",
                kind: stringValue(raw["kind"]) ?? "update",
                output: stringValue(raw["delta"]) ?? stringValue(raw["output"]) ?? "",
                status: fallbackStatus,
                isStreaming: fallbackStatus == "active"
            )
    }

    private func planUpdate(
        from params: [String: CodexJSONValue],
        itemID: String,
        isStreaming: Bool
    ) -> Message.PlanUpdate? {
        Message.planUpdate(itemID: itemID, raw: params, isStreaming: isStreaming)
    }

    private func toolCall(from item: ThreadItem, fallbackStatus: String) -> Message.ToolCall {
        Message.toolCall(itemID: item.id, raw: item.raw, fallbackStatus: fallbackStatus)
            ?? Message.toolCall(
                itemID: item.id,
                server: stringValue(item.raw["server"]) ?? stringValue(item.raw["serverName"]),
                tool: stringValue(item.raw["tool"]) ?? stringValue(item.raw["toolName"]) ?? "Tool",
                status: stringValue(item.raw["status"]) ?? fallbackStatus,
                isStreaming: fallbackStatus == "inProgress"
            )
    }

    private func finishMainStreamingToolMessages() {
        for index in messages.indices where messages[index].isStreaming {
            if messages[index].commandRun != nil {
                messages[index].commandRun?.isStreaming = false
            }
            if messages[index].fileChange != nil {
                messages[index].fileChange?.isStreaming = false
            }
            if messages[index].planUpdate != nil {
                messages[index].planUpdate?.isStreaming = false
            }
            if messages[index].toolCall != nil {
                messages[index].toolCall?.isStreaming = false
            }
            if messages[index].notice != nil {
                messages[index].notice?.isStreaming = false
            }
            if messages[index].commandRun != nil || messages[index].fileChange != nil || messages[index].planUpdate != nil || messages[index].toolCall != nil || messages[index].notice != nil {
                messages[index].isStreaming = false
            }
        }
    }

    private func startApprovalStoreMirror() {
        approvalEventTask?.cancel()
        approvalEventTask = Task { @MainActor [weak self] in
            var lastIDs: Set<String> = []
            var lastUserInputID: String?
            while !Task.isCancelled {
                guard let self, let codex else { break }
                let prompts = codex.store.pendingApprovals.map { CodexApprovalPrompt(request: $0) }
                let ids = Set(prompts.map(\.id))
                if ids != lastIDs || prompts != approvalPrompts {
                    let newPrompts = prompts.filter { !lastIDs.contains($0.id) }
                    approvalPrompts = prompts
                    for prompt in newPrompts {
                        appendActivity(.notice, title: "Approval requested", detail: prompt.primaryValue ?? prompt.kind.displayName)
                    }
                    lastIDs = ids
                }

                let userInput = codex.store.pendingUserInput
                if userInput?.id != lastUserInputID {
                    if let lastUserInputID {
                        interactivePrompts.removeAll(where: { $0.id == lastUserInputID })
                    }
                    if let userInput {
                        let prompt = CodexInteractivePrompt(request: userInput)
                        if !interactivePrompts.contains(where: { $0.id == prompt.id }) {
                            interactivePrompts.append(prompt)
                            appendActivity(.notice, title: "Input requested", detail: prompt.detail)
                        }
                    }
                    lastUserInputID = userInput?.id
                }

                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func startInteractivePromptEventListener() {
        interactivePromptEventTask?.cancel()
        interactivePromptEventTask = Task { [interactivePromptBridge, weak self] in
            let events = await interactivePromptBridge.events()
            for await event in events {
                await MainActor.run {
                    self?.apply(event)
                }
            }
        }
    }

    // MARK: - Value helpers

    private func stringValue(_ value: CodexJSONValue?) -> String? {
        switch value {
        case .string(let string): return string
        case .int(let int): return String(int)
        case .double(let double): return String(double)
        case .bool(let bool): return String(bool)
        case .array(let values): return values.compactMap(stringValue).joined(separator: " ")
        case .dictionary, .null, nil: return nil
        }
    }

    private func dictionaryValue(_ value: CodexJSONValue?) -> [String: CodexJSONValue]? {
        if case .dictionary(let object)? = value { return object }
        return nil
    }

    private func intValue(_ value: CodexJSONValue?) -> Int? {
        switch value {
        case .int(let int): return int
        case .double(let double): return Int(double)
        case .string(let string): return Int(string)
        case .bool, .array, .dictionary, .null, nil: return nil
        }
    }

    private func appendMessage(_ role: Message.Role, _ text: String, detail: String? = nil) {
        messages.append(Message(role: role, text: text, detail: detail))
    }

    private func appendActivity(_ kind: Activity.Kind, title: String, detail: String) {
        activities.insert(Activity(kind: kind, title: title, detail: clippedDetail(detail)), at: 0)
        if activities.count > 80 {
            activities.removeLast(activities.count - 80)
        }
    }

    private func formattedTranscript() -> String {
        messages.map { message in
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = text.isEmpty ? (message.commandRun?.command ?? "") : text
            return "\(message.role.rawValue): \(content)"
        }
        .joined(separator: "\n\n")
    }

    private func clippedDetail(_ detail: String) -> String {
        let normalized = detail.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard normalized.count > 160 else { return normalized }
        return String(normalized.prefix(160)) + "…"
    }

    private func previewText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tokenSummary(_ usage: some Any) -> String {
        "Updated"
    }

    private func humanItemType(_ type: String) -> String {
        switch type {
        case "agentMessage", "assistantMessage": return "Codex message"
        case "commandExecution": return "Command"
        case "fileChange", "patch": return "File change"
        case "reasoning": return "Reasoning"
        default: return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func humanMethod(_ method: String) -> String {
        method
            .split(separator: "/")
            .last
            .map(String.init)?
            .replacingOccurrences(of: ".", with: " ")
            .capitalized ?? method
    }

    private func friendlyError(_ error: Error) -> String {
        let described = String(describing: error)
        return described.count > 200 ? String(described.prefix(200)) + "…" : described
    }

    private func applyFastCommand() {
        guard let target = modelOptions.first(where: { option in
            option.id.caseInsensitiveCompare("speed") == .orderedSame ||
                option.modelIdentifier?.caseInsensitiveCompare("speed") == .orderedSame ||
                option.displayName.localizedCaseInsensitiveContains("speed")
        }) else {
            appendActivity(
                .notice,
                title: "Fast mode",
                detail: "No Speed model returned by app-server"
            )
            return
        }
        selectModel(target)

        let supported = target.supportedReasoning.isEmpty
            ? CodexReasoningSelection.defaultOptions
            : target.supportedReasoning
        if let fastReasoning = [.minimal, .low, .none].first(where: { supported.contains($0) }) {
            reasoningSelection = fastReasoning
        }

        appendActivity(
            .notice,
            title: "Fast mode",
            detail: "\(modelSelection.displayName) \(reasoningSelection.displayName)"
        )
    }

    private func applyReasoningCommand() {
        let supported = modelSelection.supportedReasoning.isEmpty
            ? CodexReasoningSelection.defaultOptions
            : modelSelection.supportedReasoning
        guard !supported.isEmpty else { return }

        if let index = supported.firstIndex(of: reasoningSelection) {
            reasoningSelection = supported[(index + 1) % supported.count]
        } else {
            reasoningSelection = modelSelection.defaultReasoning ?? supported.first ?? .medium
        }

        appendActivity(.notice, title: "Reasoning", detail: reasoningSelection.displayName)
    }

    private func currentStatusSummary() -> String {
        let activeSubagents = subagents.filter { $0.status == .running }.count
        let sideChatState = sideChat == nil ? "closed" : "open"
        return [
            "Connection: \(connectionState.label)",
            "Project: \(workspacePath)",
            "Chat: \(currentThreadID ?? "preparing")",
            "Model: \(modelSelection.displayName) \(reasoningSelection.displayName)",
            "Approval: \(approvalSelection.displayName)",
            "Messages: \(messages.count)",
            "Side chat: \(sideChatState)",
            "Subagents: \(activeSubagents) active / \(subagents.count) total"
        ].joined(separator: "\n")
    }

    private func turnInput(
        prompt: String,
        skills: [CodexSlashCommand],
        mentions: [CodexInput] = []
    ) -> [CodexInput] {
        let skillInputs = skills.compactMap { command -> CodexInput? in
            guard let name = command.skillName, let path = command.skillPath else { return nil }
            return .skill(name: name, path: path)
        }
        return skillInputs + mentions + [.text(prompt)]
    }

    /// Mention input items for `@name` tokens still present in the prompt.
    private func mentionInputItems(for prompt: String) -> [CodexInput] {
        draftMentions.values
            .filter { prompt.contains("@\($0.fileName)") }
            .map { CodexInput.mention(name: $0.fileName, path: $0.absolutePath) }
    }

    // MARK: - @-mention file search

    func updateMentionQuery(_ query: String?) {
        mentionSearchTask?.cancel()
        guard let query else {
            mentionResults = []
            return
        }
        mentionSearchTask = Task { [weak self] in
            guard let self else { return }
            // Debounce keystrokes before hitting the app-server.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let codex else { return }
            do {
                let response = try await codex.fuzzyFileSearch(query: query, roots: [workspacePath])
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.mentionResults = response.files
                }
            } catch {
                await MainActor.run { self.mentionResults = [] }
            }
        }
    }

    func selectMention(_ result: FuzzyFileSearchResult) {
        draftMentions[result.fileName] = result
        mentionResults = []
        appendActivity(.notice, title: "Mentioned file", detail: result.path)
    }

    // MARK: - File change undo

    /// Reverts a file change in the workspace via git. New files are removed;
    /// modified/deleted files are restored with `git checkout`.
    func undoFileChange(_ change: CodexChatMessage.FileChange) {
        guard let relativePath = gitRelativePath(for: change) else {
            appendActivity(.notice, title: "Undo unavailable", detail: "No file path to revert")
            return
        }
        let kind = change.kind.lowercased()
        let isAddition = kind.contains("add") || kind.contains("create")
        let cwd = workspacePath

        Task { [weak self] in
            guard let self, let codex else { return }
            do {
                if isAddition {
                    _ = try await codex.execCommand(["git", "clean", "-f", "--", relativePath], cwd: cwd)
                } else {
                    _ = try await codex.execCommand(["git", "checkout", "--", relativePath], cwd: cwd)
                }
                await MainActor.run {
                    self.appendActivity(.notice, title: "Reverted", detail: relativePath)
                }
            } catch {
                await MainActor.run {
                    self.appendActivity(.notice, title: "Undo failed", detail: self.friendlyError(error))
                }
            }
        }
    }

    private func gitRelativePath(for change: CodexChatMessage.FileChange) -> String? {
        guard let path = change.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        let root = workspacePath.hasSuffix("/") ? workspacePath : workspacePath + "/"
        if path.hasPrefix(root) {
            return String(path.dropFirst(root.count))
        }
        return path
    }

    private func clearThreadState() {
        streamTask?.cancel()
        sideChatStreamTask?.cancel()
        streamTask = nil
        sideChatStreamTask = nil
        activeTurn = nil
        activeSideChatTurn = nil
        thread = nil
        sideChatThread = nil
        isSending = false
        isSideChatSending = false
        sideChatDraft = ""
        currentPlan = []
        currentPlanExplanation = nil
        currentDiff = nil
        approvalPrompts.removeAll()
        interactivePrompts.removeAll()
        Task { await interactivePromptBridge.cancelAll() }
        pendingSkillInputs.removeAll()
        messages.removeAll()
        lifecycleEvents.removeAll()
        subagents.removeAll()
        sideChat = nil
        assistantMessageIDsByItemID = [:]
        commandMessageIDsByItemID = [:]
        fileChangeMessageIDsByItemID = [:]
        planMessageIDsByItemID = [:]
        toolCallMessageIDsByItemID = [:]
        noticeMessageIDsByItemID = [:]
        sideChatAssistantMessageIDsByItemID = [:]
        sideChatCommandMessageIDsByItemID = [:]
        sideChatFileChangeMessageIDsByItemID = [:]
        sideChatPlanMessageIDsByItemID = [:]
        sideChatToolCallMessageIDsByItemID = [:]
        sideChatNoticeMessageIDsByItemID = [:]
        locallyOpenedSideChat = nil
        agentStateMapper.reset()
        syncAgentState()
    }

    private func resetSessionState() {
        notificationTask?.cancel()
        loginTask?.cancel()
        approvalEventTask?.cancel()
        interactivePromptEventTask?.cancel()
        notificationTask = nil
        loginTask = nil
        approvalEventTask = nil
        interactivePromptEventTask = nil
        approvalPrompts.removeAll()
        interactivePrompts.removeAll()
        Task { await interactivePromptBridge.cancelAll() }
        codex = nil
        isAuthenticated = true
        authLabel = "Checking auth"
        deviceCode = nil
        deviceCodeURL = nil
        recentChats = []
        recentProjects = CodexProjectSummary.projects(from: [], currentWorkspacePath: workspacePath)
        clearSearchResults()
        mcpServers = []
        isLoadingMCPServers = false
        mcpErrorMessage = nil
        plugins = []
        isLoadingPlugins = false
        pluginErrorMessage = nil
        pluginLoadErrors = []
        modelOptions = CodexModelSelection.defaultOptions
        approvalOptions = CodexApprovalSelection.defaultOptions
        collaborationModes = CodexCollaborationModeOption.defaultOptions
        isPlanModeEnabled = false
        modelSelection = .appServerDefault
        slashCommands = CodexSlashCommand.observedCommands
        pendingSkillInputs.removeAll()
        clearThreadState()
    }

}

private extension CodexChatModel {
    static func visibleThreadSummaries(from raw: CodexJSONValue) -> [CodexThreadSummary] {
        CodexThreadSummary.summaries(from: raw)
            .filter { $0.parentThreadID == nil && !$0.isEphemeral }
    }

    static func mergedThreadSummaries(_ summaries: [CodexThreadSummary]) -> [CodexThreadSummary] {
        var seen: Set<String> = []
        var merged: [CodexThreadSummary] = []
        for summary in summaries where seen.insert(summary.id).inserted {
            merged.append(summary)
        }
        return merged
    }
}
