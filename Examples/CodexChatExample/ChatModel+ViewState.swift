import CodexCore
import CodexCoreUI

@MainActor
extension CodexChatModel {
    var connectionState: ConnectionState {
        authSession.connectionState
    }

    var draft: String {
        get { composerSession.draft }
        set { composerSession.draft = newValue }
    }

    var sideChatDraft: String {
        get { composerSession.sideChatDraft }
        set { composerSession.sideChatDraft = newValue }
    }

    var messages: [Message] {
        runtimeSession.messages
    }

    var lifecycleEvents: [CodexAgentLifecycleEvent] {
        runtimeSession.lifecycleEvents
    }

    var sideChat: CodexSideChatState? {
        runtimeSession.sideChat
    }

    var subagents: [CodexSubagentState] {
        runtimeSession.subagents
    }

    var recentChats: [CodexThreadSummary] {
        threadListSession.recentChats
    }

    var recentProjects: [CodexProjectSummary] {
        threadListSession.recentProjects
    }

    var searchResults: [CodexThreadSearchResult] {
        threadListSession.searchResults
    }

    var isSearchingChats: Bool {
        threadListSession.isSearching
    }

    var searchErrorMessage: String? {
        threadListSession.searchErrorMessage
    }

    var mcpServers: [CodexMCPServerStatus] {
        runtimeSession.integrationCatalogSession.mcpServers
    }

    var isLoadingMCPServers: Bool {
        runtimeSession.integrationCatalogSession.isLoadingMCPServers
    }

    var mcpErrorMessage: String? {
        runtimeSession.integrationCatalogSession.mcpErrorMessage
    }

    var plugins: [CodexPluginSummary] {
        runtimeSession.integrationCatalogSession.plugins
    }

    var isLoadingPlugins: Bool {
        runtimeSession.integrationCatalogSession.isLoadingPlugins
    }

    var pluginErrorMessage: String? {
        runtimeSession.integrationCatalogSession.pluginErrorMessage
    }

    var pluginLoadErrors: [String] {
        runtimeSession.integrationCatalogSession.pluginLoadErrors
    }

    var approvalPrompts: [CodexApprovalPrompt] {
        promptRuntime.approvalPrompts
    }

    var interactivePrompts: [CodexInteractivePrompt] {
        promptRuntime.interactivePrompts
    }

    var activities: [Activity] {
        activityLog.activities
    }

    var isSending: Bool {
        runtimeSession.isSending
    }

    var isSideChatSending: Bool {
        runtimeSession.isSideChatSending
    }

    var isAuthenticated: Bool {
        authSession.isAuthenticated
    }

    var authLabel: String {
        authSession.authLabel
    }

    var deviceCodeURL: String? {
        authSession.deviceCodeURL
    }

    var deviceCode: String? {
        authSession.deviceCode
    }

    var approvalSelection: CodexApprovalSelection {
        get { configurationSession.approvalSelection }
        set { configurationSession.approvalSelection = newValue }
    }

    var approvalOptions: [CodexApprovalSelection] {
        configurationSession.approvalOptions
    }

    var isPlanModeEnabled: Bool {
        get { configurationSession.isPlanModeEnabled }
        set { configurationSession.setPlanModeEnabled(newValue) }
    }

    var activeGoal: ThreadGoal? {
        runtimeSession.activeGoal
    }

    var isGoalPursuitEnabled: Bool {
        runtimeSession.isGoalPursuitEnabled
    }

    var currentPlan: [TurnPlanStep] {
        runtimeSession.currentPlan
    }

    var currentPlanExplanation: String? {
        runtimeSession.currentPlanExplanation
    }

    var currentDiff: String? {
        runtimeSession.currentDiff
    }

    var followUpBehavior: CodexFollowUpBehavior {
        get { composerSession.followUpBehavior }
        set { composerSession.followUpBehavior = newValue }
    }

    var mentionResults: [FuzzyFileSearchResult] {
        composerSession.mentionResults
    }

    var modelSelection: CodexModelSelection {
        get { configurationSession.modelSelection }
        set { configurationSession.selectModel(newValue) }
    }

    var modelOptions: [CodexModelSelection] {
        configurationSession.modelOptions
    }

    var reasoningSelection: CodexReasoningSelection {
        get { configurationSession.reasoningSelection }
        set { configurationSession.reasoningSelection = newValue }
    }

    var slashCommands: [CodexSlashCommand] {
        configurationSession.slashCommands
    }

    var isConnected: Bool {
        authSession.isConnected
    }

    var isConnecting: Bool {
        authSession.isConnecting
    }

    var connectionErrorMessage: String? {
        authSession.connectionErrorMessage
    }

    var serverName: String? {
        authSession.serverName
    }

    var isThreadReady: Bool {
        threadSession.isThreadReady
    }

    var currentThreadID: String? {
        threadSession.currentThreadID
    }

    var currentChatTitle: String {
        guard let currentThreadID else { return "Current chat" }
        return recentChats.first(where: { $0.id == currentThreadID })?.title ?? "Current chat"
    }

    var showsChatWorkspace: Bool {
        isConnected && isAuthenticated
    }

    var canUseGoalPursuit: Bool {
        showsChatWorkspace
    }

    var canSend: Bool {
        if case .connected = connectionState,
           isAuthenticated,
           !composerSession.trimmedDraft.isEmpty,
           !isSending || canSendFollowUp {
            return true
        }
        return false
    }

    var canSendFollowUp: Bool {
        runtimeSession.canSendFollowUp(hasActiveTurnHandle: runtimeSession.activeTurn != nil)
    }

    var followUpHint: String? {
        composerSession.followUpHint(isSending: isSending, canSendFollowUp: canSendFollowUp)
    }

    var canSendSideChatMessage: Bool {
        if case .connected = connectionState,
           isAuthenticated,
           isThreadReady,
           sideChat != nil,
           !composerSession.trimmedSideChatDraft.isEmpty,
           !isSideChatSending {
            return true
        }
        return false
    }

    var canUsePlanMode: Bool {
        configurationSession.canUsePlanMode
    }

    var threadLaunchConfiguration: CodexThreadLaunchConfiguration {
        CodexThreadLaunchConfiguration(
            approvalMode: approvalSelection.approvalMode,
            cwd: workspacePath,
            modelIdentifier: modelSelection.modelIdentifier,
            sandbox: approvalSelection.sandbox
        )
    }

    var turnLaunchConfiguration: CodexTurnLaunchConfiguration {
        CodexTurnLaunchConfiguration(
            approvalMode: approvalSelection.approvalMode,
            cwd: workspacePath,
            effort: reasoningSelection.effort,
            modelIdentifier: modelSelection.modelIdentifier,
            sandbox: approvalSelection.sandbox,
            parameters: configurationSession.turnParameterOverrides
        )
    }
}
