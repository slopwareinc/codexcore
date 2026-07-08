import CodexCore
import CodexCoreUI

@MainActor
extension CodexCoreAppModel {
    var connectionState: ConnectionState {
        authSession.connectionState
    }

    var draft: String {
        get { composerSession.draft(for: currentThreadID) }
        set {
            composerSession.setActiveThreadID(currentThreadID)
            composerSession.setDraft(newValue, for: currentThreadID)
        }
    }

    var sideChatDraft: String {
        get { composerSession.sideChatDraft }
        set { composerSession.sideChatDraft = newValue }
    }

    var messages: [Message] {
        runtimeSession.messages.filter { structuredPanelDismissalState.isVisible(messageID: $0.id) }
    }

    /// The durable tool-panel state (terminals, browsers, sidebar open/selection)
    /// for the current chat. Sessions persist across chat switches via the store.
    var workspacePanelState: CodexWorkspacePanelState {
        workspacePanel.state(for: currentThreadID)
    }

    /// Recent chats whose tool surfaces stay mounted for instant switching.
    var mountedWorkspacePanels: [CodexWorkspacePanelState] {
        workspacePanel.mountedToolStates
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

    var allSidebarChats: [CodexThreadSummary] {
        threadListSession.allChats.isEmpty ? threadListSession.recentChats : threadListSession.allChats
    }

    var recentProjects: [CodexProjectSummary] {
        threadListSession.recentProjects
    }

    var sidebarSnapshot: CodexSidebarSnapshot {
        sidebarNavigationSession.snapshot(
            projects: recentProjects,
            chats: allSidebarChats,
            currentWorkspacePath: workspacePath,
            currentThreadID: currentThreadID,
            pinnedThreadIDs: pinnedThreadIDs
        )
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

    var skills: [CodexSkillSummary] {
        runtimeSession.integrationCatalogSession.skills
    }

    var isLoadingSkills: Bool {
        runtimeSession.integrationCatalogSession.isLoadingSkills
    }

    var skillErrorMessage: String? {
        runtimeSession.integrationCatalogSession.skillErrorMessage
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

    var gitReviewSession: CodexGitReviewSession? {
        CodexGitReviewSnapshot
            .fromTurnDiff(branchName: gitBranch, turnDiff: currentDiff)
            .map { snapshot in
                CodexGitReviewSession(snapshot: snapshot)
            }
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
        return allSidebarChats.first(where: { $0.id == currentThreadID })?.title ?? "Current chat"
    }

    var showsChatWorkspace: Bool {
        isConnected && isAuthenticated
    }

    var canSend: Bool {
        if case .connected = connectionState,
           isAuthenticated,
           !composerSession.trimmedDraft(for: currentThreadID).isEmpty,
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
