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

    var sideChat: CodexSideChatState? {
        runtimeSession.sideChat
    }

    var subagents: [CodexSubagentState] {
        runtimeSession.subagents
    }

    var subagentPresentationCoordinator: CodexSubagentPresentationCoordinator? {
        runtimeSession.subagentPresentationCoordinator
    }

    var allSidebarChats: [CodexThreadSummary] {
        threadListSession.allChats.isEmpty ? threadListSession.recentChats : threadListSession.allChats
    }

    var archivedSidebarChats: [CodexThreadSummary] {
        threadListSession.archivedChats
    }

    var archivedSidebarNextCursor: String? {
        threadListSession.archivedNextCursor
    }

    var isLoadingArchivedSidebarChats: Bool {
        threadListSession.isLoadingArchived
    }

    var archivedSidebarErrorMessage: String? {
        threadListSession.archivedErrorMessage
    }

    var isSidebarMutating: Bool {
        !pendingSidebarMutationIDs.isEmpty
    }

    var recentProjects: [CodexProjectSummary] {
        CodexSidebarProjection.presentedProjects(
            serverProjects: threadListSession.serverProjects,
            chats: allSidebarChats,
            currentWorkspacePath: workspacePath,
            projectlessThreadIDs: projectlessThreadIDs,
            sourceFoldersByPrimaryPath: projectSourceFoldersByPrimaryPath
        )
    }

    var workspaceRoots: [String] {
        projectSourceFoldersByPrimaryPath[
            CodexProjectSummary.normalizedPath(workspacePath)
        ] ?? [CodexProjectSummary.normalizedPath(workspacePath)]
    }

    var protocolWorkspaceRoots: [CodexSchemaAbsolutePathBuf] {
        protocolRuntimeRoots(workspaceRoots)
    }

    func protocolRuntimeRoots(_ roots: [String]) -> [CodexSchemaAbsolutePathBuf] {
        (roots + [codexHome.visualizationsDirectoryURL.path])
            .reduce(into: [String]()) { result, path in
                let normalized = CodexProjectSummary.normalizedPath(path)
                if !result.contains(normalized) { result.append(normalized) }
            }
            .map { CodexSchemaAbsolutePathBuf(.string($0)) }
    }

    var sidebarSnapshot: CodexSidebarSnapshot {
        sidebarNavigationSession.snapshot(
            projects: recentProjects,
            chats: allSidebarChats,
            currentWorkspacePath: workspacePath,
            currentThreadID: currentThreadID,
            pinnedThreadIDs: pinnedThreadIDs,
            projectlessThreadIDs: projectlessThreadIDs,
            threadStatusEntries: canonicalThreadStatusEntries,
            archivedChats: archivedSidebarChats,
            sections: threadSections.enumerated().map {
                CodexSidebarSectionSummary(schema: $0.element, position: $0.offset)
            },
            archivedNextCursor: archivedSidebarNextCursor,
            activeLoadState: threadListSession.activeLoadState,
            archivedLoadState: {
                if threadListSession.isLoadingArchived { return .loading }
                if let message = threadListSession.archivedErrorMessage { return .failed(message) }
                return threadListSession.hasLoadedArchived ? .loaded : .idle
            }(),
            actionErrorMessage: sidebarActionError,
            pendingThreadIDs: pendingSidebarMutationIDs
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

    var apps: [CodexAppSummary] {
        observedIntegrationCatalogSession.apps
    }

    var isLoadingApps: Bool {
        observedIntegrationCatalogSession.isLoadingApps
    }

    var appErrorMessage: String? {
        observedIntegrationCatalogSession.appErrorMessage
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
            turnDiff: currentDiff,
            revision: currentDiffReviewRevision
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

    /// One fact-only inventory feeds both the floating Summary and the
    /// workspace New Tab page. Panel selection and layout remain in
    /// `CodexWorkspaceTabs`; only canonical/resource facts cross this seam.
    var threadResourceInventory: CodexThreadResourceInventory? {
        guard let currentThreadID,
              let snapshot = selectedThreadSessionSnapshot?.canonical
        else { return nil }

        let threadID = ThreadID(currentThreadID)
        var facts: [CodexThreadResourceFact] = []
        let origin = CodexThreadResourceOrigin(
            threadID: threadID,
            turnID: snapshot.threads[threadID]?.turnOrder.last
        )
        let summary = workspaceSummaryContext

        for source in summary.sourceFiles {
            facts.append(.init(
                id: "source:\(threadID.rawValue):\(source.id)",
                kind: .source,
                title: source.displayName,
                detail: source.path,
                origin: origin,
                metadata: .init(path: source.path)
            ))
        }

        for subagent in subagents where subagent.isVisibleInFloatingSummary {
            facts.append(.init(
                id: "subagent:\(threadID.rawValue):\(subagent.id)",
                kind: .subagent,
                title: subagent.floatingSummaryTitle,
                status: .init(rawValue: subagent.status.rawValue),
                origin: origin,
                metadata: .init(childThreadID: ThreadID(subagent.id))
            ))
        }

        if let sideChat {
            facts.append(.init(
                id: "side-chat:\(threadID.rawValue):\(sideChat.id)",
                kind: .sideChat,
                title: sideChat.title,
                origin: origin,
                metadata: .init(sourceID: sideChat.id)
            ))
        }

        if let review = gitReviewSession {
            let reviewStats = review.commitStats
            let reviewDetail = reviewStats.isEmpty
                ? review.snapshot.branchName
                : "\(review.snapshot.branchName) · +\(reviewStats.addedLines) -\(reviewStats.removedLines)"
            facts.append(.init(
                id: "review:\(threadID.rawValue):workspace",
                kind: .review,
                title: reviewStats.isEmpty ? "Review" : "Changes",
                detail: reviewDetail,
                origin: origin,
                metadata: .init(sourceID: review.snapshot.revision.sourceID)
            ))
            if review.snapshot.pullRequestExists {
                facts.append(.init(
                    id: "pull-request:\(threadID.rawValue):\(review.snapshot.branchName)",
                    kind: .pullRequest,
                    title: "Pull request",
                    detail: review.snapshot.branchName,
                    origin: origin,
                    metadata: .init(branch: review.snapshot.branchName)
                ))
            }
        }

        for session in workspacePanelState.browserSessions {
            let url = session.currentURL?.absoluteString ?? session.addressText
            facts.append(.init(
                id: "web:\(threadID.rawValue):\(session.id)",
                kind: .webActivity,
                title: session.title,
                detail: url.nilIfBlank,
                origin: origin,
                metadata: .init(url: url)
            ))
        }

        for server in mcpServers {
            for entry in server.resources + server.resourceTemplates {
                facts.append(.init(
                    id: "mcp-resource:\(threadID.rawValue):\(server.name):\(entry.name)",
                    kind: .mcpResource,
                    title: entry.displayName,
                    detail: entry.detail,
                    origin: origin,
                    metadata: .init(
                        url: entry.name,
                        server: server.name
                    )
                ))
            }
        }

        for app in apps {
            facts.append(.init(
                id: "mcp-app:\(threadID.rawValue):\(app.id)",
                kind: .mcpApp,
                title: app.displayName,
                detail: app.detail,
                status: app.callable ? .available : .failed,
                origin: origin,
                metadata: .init(url: app.logoURL, appName: app.id)
            ))
        }

        var supplementalRevision: UInt64 = 14_695_981_039_346_656_037
        func combine(_ value: String) {
            for byte in value.utf8 {
                supplementalRevision ^= UInt64(byte)
                supplementalRevision &*= 1_099_511_628_211
            }
            supplementalRevision ^= 0xFF
            supplementalRevision &*= 1_099_511_628_211
        }
        combine(workspacePath)
        combine(gitBranch ?? "")
        combine(String(facts.count))
        for fact in facts.sorted(by: { $0.id < $1.id }) {
            combine(fact.id)
            combine(fact.title)
            combine(fact.detail ?? "")
            combine(fact.status.rawValue)
        }

        let input = CodexThreadResourceProjectionInput(
            snapshot: snapshot,
            threadID: threadID,
            supplementalFacts: facts,
            supplementalRevision: supplementalRevision
        )
        _ = threadResourceProjectionCache.apply(input)
        return threadResourceProjectionCache.inventory
    }

    private var currentDiffReviewRevision: CodexGitReviewRevision {
        guard let sourceID = runtimeSession.currentDiffSourceID,
              let revision = runtimeSession.currentDiffRevision else { return .manual }
        return CodexGitReviewRevision(sourceID: sourceID, value: revision.rawValue)
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
