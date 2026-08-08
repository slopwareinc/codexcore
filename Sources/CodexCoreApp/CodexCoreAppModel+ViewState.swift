import CodexCore
import CodexCoreUI

@MainActor
extension CodexCoreAppModel {
    private var observedIntegrationCatalogSession: CodexIntegrationCatalogSession {
        _ = integrationCatalogRevision
        return runtimeSession.integrationCatalogSession
    }

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

    var responseAnnotations: [CodexResponseTextAnnotation] {
        get { composerSession.responseAnnotations(for: currentThreadID) }
        set {
            composerSession.setActiveThreadID(currentThreadID)
            composerSession.setResponseAnnotations(newValue, for: currentThreadID)
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
        // Register the coordinator bridge as an observation dependency. The
        // coordinator publishes metadata independently of parent snapshots.
        _ = subagentPresentationRevision
        return runtimeSession.subagents
    }

    var allSidebarChats: [CodexThreadSummary] {
        threadListSession.allChats.isEmpty ? threadListSession.recentChats : threadListSession.allChats
    }

    var recentProjects: [CodexProjectSummary] {
        let projectChats = allSidebarChats.filter { !projectlessThreadIDs.contains($0.id) }
        let inferred = CodexProjectSummary.projects(
            from: projectChats,
            currentWorkspacePath: workspacePath
        )
        guard !projectSourceFoldersByPrimaryPath.isEmpty else { return inferred }

        let claimedRoots = Set(projectSourceFoldersByPrimaryPath.values.flatMap { $0 })
        var projects = inferred.filter { !claimedRoots.contains($0.workspacePath) }

        for (primary, roots) in projectSourceFoldersByPrimaryPath {
            let members = inferred.filter { roots.contains($0.workspacePath) }
            let chatCount = members.reduce(0) { $0 + $1.chatCount }
            let updatedAt = members.compactMap(\.updatedAt).max()
            projects.append(CodexProjectSummary(
                workspacePath: primary,
                sourceFolders: roots,
                chatCount: chatCount,
                updatedAt: updatedAt
            ))
        }
        return projects.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var workspaceRoots: [String] {
        projectSourceFoldersByPrimaryPath[
            CodexProjectSummary.normalizedPath(workspacePath)
        ] ?? [CodexProjectSummary.normalizedPath(workspacePath)]
    }

    var protocolWorkspaceRoots: [CodexSchemaAbsolutePathBuf] {
        workspaceRoots.map { CodexSchemaAbsolutePathBuf(.string($0)) }
    }

    var sidebarSnapshot: CodexSidebarSnapshot {
        sidebarNavigationSession.snapshot(
            projects: recentProjects,
            chats: allSidebarChats,
            archivedChats: threadListSession.archivedChats,
            currentWorkspacePath: workspacePath,
            currentThreadID: currentThreadID,
            pinnedThreadIDs: pinnedThreadIDs,
            projectlessThreadIDs: projectlessThreadIDs,
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

    var integrationControlPlaneProvider: (any CodexIntegrationControlPlaneProvider)? {
        codex.map(CodexAppServerIntegrationControlPlaneProvider.init)
    }

    var mcpServers: [CodexMCPServerStatus] {
        observedIntegrationCatalogSession.mcpServers
    }

    var isLoadingMCPServers: Bool {
        observedIntegrationCatalogSession.isLoadingMCPServers
    }

    var mcpErrorMessage: String? {
        observedIntegrationCatalogSession.mcpErrorMessage
    }

    var plugins: [CodexPluginSummary] {
        observedIntegrationCatalogSession.plugins
    }

    var marketplaces: [CodexMarketplaceSummary] {
        observedIntegrationCatalogSession.marketplaces
    }

    var isLoadingPlugins: Bool {
        observedIntegrationCatalogSession.isLoadingPlugins
    }

    var pluginErrorMessage: String? {
        observedIntegrationCatalogSession.pluginErrorMessage
    }

    var pluginLoadErrors: [String] {
        observedIntegrationCatalogSession.pluginLoadErrors
    }

    var pluginReadDetails: [String: CodexPluginReadDetail] {
        observedIntegrationCatalogSession.pluginReadDetails
    }

    var loadingPluginReadIDs: Set<String> {
        observedIntegrationCatalogSession.loadingPluginReadIDs
    }

    var pluginReadErrors: [String: String] {
        observedIntegrationCatalogSession.pluginReadErrors
    }

    var apps: [CodexAppSummary] {
        observedIntegrationCatalogSession.apps
    }

    var isLoadingApps: Bool {
        observedIntegrationCatalogSession.isLoadingApps
    }

    var appErrorMessage: String? {
        observedIntegrationCatalogSession.appErrorMessage
    }

    var skills: [CodexSkillSummary] {
        observedIntegrationCatalogSession.skills
    }

    var isLoadingSkills: Bool {
        observedIntegrationCatalogSession.isLoadingSkills
    }

    var skillErrorMessage: String? {
        observedIntegrationCatalogSession.skillErrorMessage
    }

    var skillLoadErrors: [String] {
        observedIntegrationCatalogSession.skillLoadErrors
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
        if let snapshot = CodexGitReviewSnapshot.fromTurnDiff(
            branchName: gitBranch,
            turnDiff: currentDiff
        ) {
            return CodexGitReviewSession(snapshot: snapshot)
        }
        // A Git checkout can be reviewed, committed, and pushed before the
        // current turn has produced any edits. Without this the summary's
        // Changes, Commit or push, and Create pull request rows would go dead
        // in a perfectly normal repository; Review opens on its Last Turn
        // empty state and offers the repository sources from there.
        guard let branch = gitBranch?.nilIfBlank else { return nil }
        return CodexGitReviewSession(
            snapshot: CodexGitReviewSnapshot(branchName: branch)
        )
    }

    var followUpBehavior: CodexFollowUpBehavior {
        get { composerSession.followUpBehavior }
        set {
            guard composerSession.followUpBehavior != newValue else { return }
            composerSession.followUpBehavior = newValue
            CodexFollowUpBehaviorStorage.save(newValue, to: preferenceStore)
        }
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

    var serviceTierSelection: CodexServiceTierSelection {
        get { configurationSession.serviceTierSelection }
        set {
            guard configurationSession.selectServiceTier(newValue) else { return }
            rememberManualModelSelection(
                configurationSession.modelSelection,
                tierExplicit: true
            )
        }
    }

    var reasoningSelection: CodexReasoningSelection {
        get { configurationSession.reasoningSelection }
        set { configurationSession.reasoningSelection = newValue }
    }

    var slashCommands: [CodexSlashCommand] {
        configurationSession.slashCommands.map { command in
            switch command.id {
            case "compact", "fork":
                return command.withAvailability(currentThreadID != nil && !isSending)
            case "plan":
                return command.withAvailability(configurationSession.canUsePlanMode)
            default:
                return command
            }
        }
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
           (
               !composerSession.trimmedDraft(for: currentThreadID).isEmpty
                   || !referencedFiles.isEmpty
                   || !responseAnnotations.isEmpty
           ),
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
        let preference = threadID.flatMap { modelPreferenceByThread[$0] }
            ?? (threadID == nil ? lastManualModelPreference : nil)
        guard let preference else {
            configurationSession.selectModel(
                CodexModelSelection.preferredDefault(
                    from: configurationSession.modelOptions
                ),
                useServerDefaults: true
            )
            return
        }
        apply(configurationSession.resolveModelPreference(preference))
    }

    func rememberManualModelSelection(
        _ selection: CodexModelSelection,
        tierExplicit: Bool? = nil
    ) {
        let existing = currentThreadID.flatMap { modelPreferenceByThread[$0] }
            ?? lastManualModelPreference
        let preference = CodexModelPreference(
            model: selection,
            serviceTier: configurationSession.serviceTierSelection,
            isServiceTierExplicit: tierExplicit
                ?? existing?.isServiceTierExplicit
                ?? false
        )
        if lastManualModelPreference != preference {
            lastManualModelPreference = preference
            CodexModelPreferenceStorage.saveLastSelection(
                preference,
                to: preferenceStore
            )
        }
        if let threadID = currentThreadID {
            if modelPreferenceByThread[threadID] != preference {
                modelPreferenceByThread[threadID] = preference
                saveThreadModelPreferences()
            }
        }
    }

    func resolvedModelPreference(
        for threadID: String
    ) -> CodexResolvedModelPreference? {
        modelPreferenceByThread[threadID].map {
            configurationSession.resolveModelPreference($0)
        }
    }

    func taskWireSelection(
        for threadID: String,
        explicitTierOnly: Bool = false
    ) -> CodexTaskWireSelection {
        configurationSession.wireSelection(
            for: resolvedModelPreference(for: threadID),
            explicitTierOnly: explicitTierOnly
        )
    }

    func hydrateModelPreference(
        for threadID: String,
        modelID: String?,
        serviceTierID: String?,
        provenance: CodexModelPreference? = nil
    ) {
        let existing = modelPreferenceByThread[threadID]
        let preference = CodexModelPreference(
            modelID: modelID,
            serviceTierID: serviceTierID
                ?? CodexModelPreference.standardTierID,
            isServiceTierExplicit:
                existing?.isServiceTierExplicit
                ?? provenance?.isServiceTierExplicit
                ?? false,
            isAuthoritativeModelID: modelID != nil
        )
        let resolved = configurationSession.resolveModelPreference(preference)
        let hydrated = CodexModelPreference(
            model: resolved.model,
            serviceTier: resolved.serviceTier,
            isServiceTierExplicit: resolved.isServiceTierExplicit,
            isAuthoritativeModelID: modelID != nil
        )
        if existing != hydrated {
            modelPreferenceByThread[threadID] = hydrated
            saveThreadModelPreferences()
        }
        if currentThreadID == threadID {
            apply(resolved)
        }
    }

    private func apply(_ preference: CodexResolvedModelPreference) {
        configurationSession.selectModel(preference.model)
        _ = configurationSession.selectServiceTier(preference.serviceTier)
    }

    private func saveThreadModelPreferences() {
        CodexModelPreferenceStorage.saveThreadSelections(
            modelPreferenceByThread,
            to: preferenceStore
        )
    }
}
