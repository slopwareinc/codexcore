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

    var referencedFiles: [CodexReferencedFile] {
        get { composerSession.referencedFiles(for: currentThreadID) }
        set {
            composerSession.setActiveThreadID(currentThreadID)
            composerSession.setReferencedFiles(newValue, for: currentThreadID)
        }
    }

    var sideChatDraft: String {
        get { composerSession.sideChatDraft }
        set { composerSession.sideChatDraft = newValue }
    }

    var transcriptV2: CodexTranscriptV2 {
        runtimeSession.presentedTranscriptV2
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
            pinnedThreadIDs: pinnedThreadIDs,
            threadStatusEntries: canonicalThreadStatusEntries
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
        goalPursuitEnabled
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
        set {
            configurationSession.selectModel(newValue)
            rememberManualModelSelection(newValue)
        }
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
        currentThreadLease?.isClosed == false
    }

    var currentThreadID: String? {
        selectedThreadID
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
           (!composerSession.trimmedDraft(for: currentThreadID).isEmpty || !referencedFiles.isEmpty),
           !isSending || canSendFollowUp {
            return true
        }
        return false
    }

    var canSendFollowUp: Bool {
        runtimeSession.canSendFollowUp(canSteer: activeTurnLease != nil)
    }

    var followUpHint: String? {
        composerSession.followUpHint(isSending: isSending, canSendFollowUp: canSendFollowUp)
    }

    var queuedFollowUps: [CodexComposerSubmission] {
        composerSession.queuedFollowUpSubmissions(for: currentThreadID)
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

    func applyPreferredModel(for threadID: String?) {
        let preferredID = threadID.flatMap { modelIDByThread[$0] } ?? lastManualModelID
        let selection = preferredID.flatMap { id in
            configurationSession.modelOptions.first { option in
                option.id == id || option.modelIdentifier == id
            }
        } ?? (preferredID == CodexModelSelection.appServerDefault.id ? .appServerDefault : CodexModelSelection.preferredDefault(from: configurationSession.modelOptions))
        configurationSession.selectModel(selection)
    }

    func rememberManualModelSelection(_ selection: CodexModelSelection) {
        lastManualModelID = selection.id
        CodexModelPreferenceStorage.saveLastModelID(selection.id, to: preferenceStore)
        if let threadID = currentThreadID {
            modelIDByThread[threadID] = selection.id
            CodexModelPreferenceStorage.saveThreadModelIDs(modelIDByThread, to: preferenceStore)
        }
    }

    func rememberModelSelection(for threadID: String) {
        modelIDByThread[threadID] = configurationSession.modelSelection.id
        CodexModelPreferenceStorage.saveThreadModelIDs(modelIDByThread, to: preferenceStore)
    }
}
