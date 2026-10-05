import SwiftUI
import AppKit
import CodexCore
import CodexCoreUI

struct CodexCoreAppShell: View {
    @Bindable var model: CodexCoreAppModel
    @State private var selectedMCPApp: CodexMCPAppDescriptor?
    @State private var isSearchOccurrencesPresented = false
    @State private var isRenameSheetPresented = false
    @State private var isMCPStatusSheetPresented = false
    @State private var isStatusSheetPresented = false
    @State private var isModelMenuPresented = false
    @State private var focusComposerRequest = false
    @State private var renameDraft = ""
    @State private var projectEditTarget: CodexProjectSummary?
    @State private var projectNameDraft = ""
    @State private var projectSourceFoldersDraft: [String] = []
    @State private var sidebarOverlaySession = CodexSidebarOverlaySession()
    @AppStorage("codex.sidebar.expandedWidth")
    private var sidebarExpandedWidth: Double = Double(CodexProjectSidebar.defaultExpandedWidth)

    var body: some View {
        let sidebarSnapshot = model.sidebarSnapshot

        GeometryReader { shellProxy in
            let sidebarWidth = resolvedSidebarWidth(availableWidth: shellProxy.size.width)

            ZStack(alignment: .topLeading) {
                HStack(alignment: .top, spacing: 0) {
                    if !sidebarSnapshot.isCollapsed {
                        projectSidebar(
                            snapshot: sidebarSnapshot,
                            width: sidebarWidth
                        )
                        .layoutPriority(0)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }

                    GeometryReader { proxy in
                        routeContent(proxy: proxy, selectedRoute: sidebarSnapshot.selectedRoute)
                    }
                    .frame(minWidth: 420)
                    .layoutPriority(1)
                }

                if sidebarSnapshot.isCollapsed {
                    sidebarEdgeRevealRegion

                    if sidebarOverlaySession.isPresented {
                        projectSidebar(
                            snapshot: expandedSnapshot(from: sidebarSnapshot),
                            width: sidebarWidth
                        )
                        .shadow(
                            color: model.theme.effects.shadow.color(for: model.theme),
                            radius: model.theme.effects.shadow.radius,
                            x: 8
                        )
                        .onHover { isInside in
                            if isInside {
                                sidebarOverlaySession.pointerEnteredRevealRegion()
                            } else {
                                sidebarOverlaySession.pointerExitedRevealRegion()
                            }
                        }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .zIndex(2)
                    }
                }
            }
            .animation(
                .interactiveSpring(response: 0.22, dampingFraction: 0.94, blendDuration: 0.06),
                value: sidebarOverlaySession.isPresented
            )
        }
        .frame(minWidth: CodexProjectSidebar.minimumExpandedShellWidth, minHeight: 540)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            model.setConversationViewVisible(
                routeDisplaysConversation(sidebarSnapshot.selectedRoute)
            )
        }
        .onDisappear {
            model.setConversationViewVisible(false)
        }
        .onChange(of: sidebarSnapshot.selectedRoute) { _, route in
            model.setConversationViewVisible(routeDisplaysConversation(route))
        }
        .onChange(of: sidebarSnapshot.isCollapsed) { _, isCollapsed in
            if !isCollapsed {
                sidebarOverlaySession.dismissImmediately()
            }
        }
        .onExitCommand {
            sidebarOverlaySession.dismissImmediately()
        }
        .overlay(alignment: .topTrailing) {
            if !model.approvalPrompts.isEmpty || !model.interactivePrompts.isEmpty {
                VStack(alignment: .trailing, spacing: 10) {
                    if let error = model.verificationPromptError { CodexErrorBanner(message: error) }
                    if !model.approvalPrompts.isEmpty {
                        CodexApprovalRequestsPanel(
                            prompts: model.approvalPrompts,
                            onDecision: { id, decision in
                                model.resolveApprovalPrompt(id: id, decision: decision)
                            }
                        )
                    }

                    ForEach(model.interactivePrompts.filter { $0.mcpElicitationMode?.isUserVerification == true }) { prompt in
                        if case .userVerification(let params) = prompt.mcpElicitationMode {
                            CodexAppVerificationApprovalView(
                                features: model.accountFeatures, params: params,
                                onVerified: { model.submitVerificationProof(id: prompt.id, proof: $0) },
                                onCancelled: { model.declineInteractivePrompt(id: prompt.id) }
                            ).id(prompt.id)
                        }
                    }

                    if !model.interactivePrompts.isEmpty {
                        CodexInteractivePromptsPanel(
                            prompts: model.interactivePrompts.filter { $0.mcpElicitationMode?.isUserVerification != true },
                            onSubmit: { id, answers in model.submitInteractivePrompt(id: id, answers: answers) },
                            onAccept: { id in model.acceptInteractivePrompt(id: id) },
                            onDecline: { id in model.declineInteractivePrompt(id: id) }
                        )
                    }

                }
                .codexAgentTheme(model.theme)
                .padding(.top, CodexWindowChromeMetrics.titlebarHeight)
                .padding(.trailing, 18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay {
            if model.sidebarSnapshot.isSearchOverlayPresented {
                CodexCommandPaletteOverlay(
                    searchResults: model.searchResults,
                    isSearchingChats: model.isSearchingChats,
                    searchErrorMessage: model.searchErrorMessage,
                    onClose: { model.dismissSearchRoute() },
                    onSearchChats: { query in await model.searchChats(query: query) },
                    onClearSearchResults: { model.clearSearchResults() },
                    onSelectChat: { result in
                        Task { await model.resumeSearchResult(result) }
                    },
                    onSelectCommand: handleCommandPaletteAction,
                    hasMoreChatResults: model.threadListSession.searchNextCursor != nil,
                    onLoadMoreChatResults: { await model.loadMoreSearchResults() },
                    onFindOccurrences: { target, query in
                        Task {
                            await model.resumeSearchResult(target)
                            guard model.currentThreadID == target.id else { return }
                            await model.threadFeatures.findOccurrences(query)
                            isSearchOccurrencesPresented = true
                        }
                    }
                )
                .codexAgentTheme(model.theme)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .sheet(item: $selectedMCPApp) { descriptor in
            if let provider = model.integrationControlPlaneProvider {
                let accountRevision = model.accountContextRevision
                CodexMCPAppView(descriptor: descriptor, provider: provider, displayMode: .fullscreen,
                    onSendMessage: { descriptor, text in Task { await model.sendMCPAppMessage(text, threadID: descriptor.threadID, expectedAccountRevision: accountRevision) } },
                    onUpdateModelContext: { model.updateMCPAppContext($0, value: $1, expectedAccountRevision: accountRevision) },
                    onClose: { selectedMCPApp = nil })
                    .frame(minWidth: 740, minHeight: 650).codexAgentTheme(model.theme)
            } else { Text("Reconnect to load this app.").padding(24) }
        }
        .onChange(of: model.currentThreadID) { _, id in
            if selectedMCPApp?.threadID != id { selectedMCPApp = nil }
        }
        .onChange(of: model.accountContextRevision) { selectedMCPApp = nil }
        .onChange(of: model.isConnected) { _, connected in if !connected { selectedMCPApp = nil } }
        .sheet(isPresented: $isSearchOccurrencesPresented) {
            CodexThreadFeaturesSheet(controller: model.threadFeatures, modelOptions: model.modelOptions,
                                     projects: model.recentProjects, plugins: model.plugins).codexAgentTheme(model.theme)
        }
        .sheet(isPresented: $isRenameSheetPresented) {
            RenameChatSheet(
                title: "Rename chat",
                placeholder: "Chat name",
                name: $renameDraft,
                onCancel: { isRenameSheetPresented = false },
                onSave: {
                    isRenameSheetPresented = false
                    Task { await model.renameCurrentChat(to: renameDraft) }
                }
            )
            .codexAgentTheme(model.theme)
        }
        .sheet(item: $projectEditTarget) { project in
            EditProjectSheet(
                name: $projectNameDraft,
                sourceFolders: $projectSourceFoldersDraft,
                onAddFolders: addProjectSourceFolders,
                onRemoveProject: {
                    model.removeSidebarProject(project.workspacePath)
                    projectEditTarget = nil
                },
                onCancel: { projectEditTarget = nil },
                onSave: {
                    let name = projectNameDraft
                    let roots = projectSourceFoldersDraft
                    projectEditTarget = nil
                    Task {
                        await model.updateSidebarProject(
                            project,
                            displayName: name,
                            sourceFolders: roots
                        )
                    }
                }
            )
            .codexAgentTheme(model.theme)
        }
        .sheet(isPresented: $isMCPStatusSheetPresented) {
            CodexMCPStatusSheet(
                servers: model.mcpServers,
                isLoading: model.isLoadingMCPServers,
                errorMessage: model.mcpErrorMessage,
                threadID: model.currentThreadID,
                provider: model.integrationControlPlaneProvider,
                onClose: { isMCPStatusSheetPresented = false },
                onRefresh: { Task { await model.refreshMCPServers() } }
            )
            .codexAgentTheme(model.theme)
        }
        .sheet(isPresented: $isStatusSheetPresented) {
            CodexStatusSheet(
                model: model.statusPanelModel,
                onClose: { isStatusSheetPresented = false },
                onRefreshThreadUsage: {
                    Task { await model.refreshThreadUsage() }
                }
            )
            .codexAgentTheme(model.theme)
        }
    }

    @ViewBuilder
    private func projectSidebar(
        snapshot: CodexSidebarSnapshot,
        width: CGFloat
    ) -> some View {
        CodexProjectSidebar(
            serverName: model.serverName,
            accountSummary: model.accountMenuSummary,
            isThreadReady: model.isThreadReady,
            snapshot: snapshot,
            expandedWidth: width,
            onResizeExpandedWidth: { sidebarExpandedWidth = Double($0) },
            onNewChat: { Task { await model.startNewChat() } },
            onOpenSearch: { model.selectAppRoute(.search) },
            onSelectRoute: { model.selectAppRoute($0) },
            onToggleProject: { model.toggleSidebarProject($0) },
            onMoveProject: { source, target, placement in
                model.moveSidebarProject(source, relativeTo: target, placement: placement)
            },
            onToggleProjectPin: { model.toggleSidebarProjectPin($0) },
            onRevealProject: { path in
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            },
            onRenameProject: { project in
                projectNameDraft = project.displayName
                projectSourceFoldersDraft = project.sourceFolders
                projectEditTarget = project
            },
            onArchiveProjectChats: { path in
                Task { await model.archiveSidebarProjectChats(path) }
            },
            onRemoveProject: { model.removeSidebarProject($0) },
            onStartProjectChat: { path in Task { await model.startNewChat(inProject: path) } },
            onSelectProject: { path in Task { await model.selectSidebarProject(path) } },
            onOpenFolder: { chooseWorkspaceFolder() },
            onSelectChat: { chat in Task { await model.selectSidebarChat(chat) } },
            onTogglePinChat: { chat in model.toggleSidebarChatPin(chat) },
            onArchiveChat: { chat in Task { await model.archiveSidebarChat(chat) } },
            onToggleSection: { model.toggleSidebarSection($0) },
            onToggleThreadSelection: { model.toggleSidebarThreadSelection($0) },
            onSelectAllThreads: { model.selectAllSidebarThreads() },
            onTogglePinnedSelectedChats: { model.togglePinnedSelectedSidebarChats() },
            onClearThreadSelection: { model.clearSidebarThreadSelection() },
            onArchiveSelectedChats: { Task { await model.archiveSelectedSidebarChats() } },
            onLoadArchivedChats: { Task { await model.refreshArchivedSidebarChats() } },
            onLoadMoreArchivedChats: { Task { await model.loadMoreArchivedSidebarChats() } },
            hasMoreActiveChats: model.threadListSession.activeNextCursor != nil,
            isLoadingMoreActiveChats: model.threadListSession.isLoadingMoreActive,
            onLoadMoreActiveChats: { Task { await model.loadMoreActiveChats() } },
            onUnarchiveChat: { chat in Task { await model.unarchiveSidebarChat(chat) } },
            sectionDestinations: model.threadSections.enumerated().map {
                CodexSidebarSectionSummary(schema: $0.element, position: $0.offset)
            },
            onMoveChat: { chat, sectionID in
                Task { await model.moveSidebarChat(chat, toSectionID: sectionID) }
            }
        )
    }

    private var sidebarEdgeRevealRegion: some View {
        Color.clear
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .padding(.top, CodexWindowChromeMetrics.titlebarHeight)
            .contentShape(Rectangle())
            .onHover { isInside in
                if isInside {
                    sidebarOverlaySession.pointerEnteredRevealRegion()
                } else {
                    sidebarOverlaySession.pointerExitedRevealRegion()
                }
            }
            .zIndex(3)
            .accessibilityHidden(true)
    }

    private func expandedSnapshot(from snapshot: CodexSidebarSnapshot) -> CodexSidebarSnapshot {
        var expanded = snapshot
        expanded.isCollapsed = false
        return expanded
    }

    private func resolvedSidebarWidth(availableWidth: CGFloat) -> CGFloat {
        let maximumThatPreservesContent = max(
            CodexProjectSidebar.minExpandedWidth,
            availableWidth - 420
        )
        return min(
            CodexProjectSidebar.clampExpandedWidth(CGFloat(sidebarExpandedWidth)),
            maximumThatPreservesContent
        )
    }

    private func collapsePinnedSidebar() {
        sidebarOverlaySession.dismissImmediately()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
            model.toggleSidebarCollapsed()
        }
    }

    private func routeDisplaysConversation(_ route: CodexAppRoute) -> Bool {
        switch route {
        case .chat, .search:
            true
        case .plugins, .automations, .settingsAbout:
            false
        }
    }

    @ViewBuilder
    private func routeContent(proxy: GeometryProxy, selectedRoute: CodexAppRoute) -> some View {
        switch selectedRoute {
        case .chat, .search:
            chatWorkspace(proxy: proxy)
        case .plugins:
            CodexPluginRouteView(
                plugins: model.plugins,
                marketplaces: model.marketplaces,
                apps: model.apps,
                skills: model.skills,
                mcpServers: model.mcpServers,
                isLoadingPlugins: model.isLoadingPlugins,
                isLoadingMCPServers: model.isLoadingMCPServers,
                isLoadingApps: model.isLoadingApps,
                isLoadingSkills: model.isLoadingSkills,
                pluginErrorMessage: model.pluginErrorMessage,
                mcpErrorMessage: model.mcpErrorMessage,
                appErrorMessage: model.appErrorMessage,
                skillErrorMessage: model.skillErrorMessage,
                marketplaceActionErrors: model.marketplaceActionErrors,
                pluginLoadErrors: model.pluginLoadErrors,
                skillLoadErrors: model.skillLoadErrors,
                pluginReadDetails: model.pluginReadDetails,
                loadingPluginReadIDs: model.loadingPluginReadIDs,
                pluginReadErrors: model.pluginReadErrors,
                launcherTarget: model.pluginLauncherTarget,
                pendingPluginIDs: model.pendingPluginActionIDs,
                pendingSkillIDs: model.pendingSkillActionIDs,
                pendingAppIDs: model.pendingAppActionIDs,
                pendingMarketplaceIDs: model.pendingMarketplaceActionIDs,
                onLoad: { model.requestPluginRefresh() },
                onRefresh: { model.requestPluginRefresh() },
                onAction: { model.performPluginCatalogAction($0) },
                onReadPlugin: { model.requestPluginRead($0) },
                onOpenMCPDetails: { isMCPStatusSheetPresented = true },
                provider: model.integrationControlPlaneProvider,
                threadID: model.currentThreadID,
                workingDirectories: model.workspaceRoots,
                appsNeedingAuthentication: model.pluginAuthenticationApps
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .codexAgentTheme(model.theme)
        case .automations:
            CodexAutomationRouteView(
                automations: model.automations,
                onAction: { model.performAutomationRouteAction($0) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .codexAgentTheme(model.theme)
        case .settingsAbout:
            CodexAppSettingsContent(
                model: model,
                onBackToApp: { model.selectAppRoute(.chat) }
            )
        }
    }

    private func chatWorkspace(proxy: GeometryProxy) -> some View {
        hostMCPApps(chatWorkspaceContent(proxy: proxy), threadID: model.currentThreadID)
    }

    @ViewBuilder private func hostMCPApps<Content: View>(_ content: Content, threadID: String?) -> some View {
        if let provider = model.integrationControlPlaneProvider {
            let accountRevision = model.accountContextRevision
            content.codexMCPAppHost(provider: provider,
                onOpenFullscreen: { if model.accountContextRevision == accountRevision, model.currentThreadID == $0.threadID { selectedMCPApp = $0 } },
                onSendMessage: { descriptor, text in Task { await model.sendMCPAppMessage(text, threadID: descriptor.threadID, expectedAccountRevision: accountRevision) } },
                onUpdateModelContext: { model.updateMCPAppContext($0, value: $1, expectedAccountRevision: accountRevision) },
                appResources: CodexMCPAppCatalogResource.catalog(from: model.mcpServers))
                .codexTranscriptFocus(model.transcriptFocusRequest)
                .id(model.accountContextRevision)
        } else { content }
    }

    private func chatWorkspaceContent(proxy: GeometryProxy) -> some View {
        let isCurrentVoiceTask = model.voiceSession.isActive
            && model.voiceSession.threadID == model.currentThreadID
        let bottomAccessory = AnyView(
            VStack(alignment: .leading, spacing: model.theme.spacing.sm) {
                CodexAppRuntimeNoticeFeaturesView(features: model.runtimeNotices, threadID: model.currentThreadID,
                                                 turnID: model.activeTurnLease?.key.turnID.rawValue)
                if let error = model.liveTurnSettings.errorMessage { CodexErrorBanner(message: error) }
                if let message = model.liveTurnSettings.message {
                    Text(message).font(model.theme.fonts.caption).foregroundStyle(model.theme.colors.textSecondary)
                }
                if isCurrentVoiceTask {
                CodexVoiceConversationPanel(
                    session: model.voiceSession,
                    reduceMotion: model.appearanceSettings.reduceMotion,
                    onSendText: { text in
                        Task { await model.voiceSession.sendText(text) }
                    },
                    onToggleMute: { model.toggleVoiceMute() },
                    onToggleOutputMute: { model.toggleVoiceOutputMute() },
                    onEnd: { Task { await model.stopVoiceChat() } }
                )
                }
            }
        )
        let supplementalVoicePresentation = model.voiceSession.threadID == model.currentThreadID
            ? model.voiceSession.transcriptPresentation
            : CodexVoiceTranscriptPresentation()
        let backgroundThreadID = model.currentThreadID
        let transcriptAccountRevision = model.accountContextRevision

        return CodexChatWorkspaceView(
                presentationStore: model.runtimeSession.presentationStore,
                sideChat: model.sideChat,
                subagents: model.subagents,
                subagentCoordinator: model.subagentPresentationCoordinator,
                workspacePath: model.workspacePath,
                workspaceTitle: model.recentProjects.first {
                    $0.id == model.sidebarNavigationSession.selectedProjectID
                }?.displayName,
                chatTitle: model.currentChatTitle,
                currentThreadID: model.currentThreadID,
                panel: model.workspacePanelState,
                mountedPanels: model.mountedWorkspacePanels,
                rateLimitBannerMessage: model.rateLimitBannerMessage,
                workspaceSummary: model.workspaceSummaryContext,
                gitReviewSession: model.gitReviewSession,
                backgroundTerminalActions: CodexBackgroundTerminalActions(
                    refresh: { Task { await model.refreshBackgroundTerminals(threadID: backgroundThreadID) } },
                    terminate: { processID in
                        Task {
                            await model.terminateBackgroundTerminal(
                                processID: processID,
                                threadID: backgroundThreadID
                            )
                        }
                    },
                    clean: { Task { await model.cleanBackgroundTerminals(threadID: backgroundThreadID) } }
                ),
                showsSidebarToggle: true,
                isSidebarVisible: !model.sidebarSnapshot.isCollapsed,
                leadingTitlebarInset: model.sidebarSnapshot.isCollapsed
                    ? (
                        sidebarOverlaySession.isPresented
                            ? resolvedSidebarWidth(availableWidth: proxy.size.width)
                            : CodexWindowChromeMetrics.sidebarTrafficLightReserveWidth
                    )
                    : 0,
                isThreadLoading: !model.runtimeSession.presentationStore.isSelectionHydrated,
                chatActions: currentChatActionHandlers,
                approvalOptions: model.approvalOptions,
                modelOptions: model.modelOptions,
                slashCommands: model.slashCommands,
                mcpServers: model.mcpServers,
                isLoadingMCPServers: model.isLoadingMCPServers,
                mcpErrorMessage: model.mcpErrorMessage,
                approvalSelection: $model.approvalSelection,
                isPlanModeEnabled: $model.isPlanModeEnabled,
                modelSelection: $model.modelSelection,
                isModelMenuPresented: $isModelMenuPresented,
                focusComposerRequest: $focusComposerRequest,
                serviceTierSelection: $model.serviceTierSelection,
                reasoningSelection: $model.reasoningSelection,
                draft: $model.draft,
                referencedFiles: $model.referencedFiles,
                responseAnnotations: $model.responseAnnotations,
                sideChatDraft: $model.sideChatDraft,
                isSending: model.isSending,
                isSideChatSending: model.isSideChatSending,
                canSend: model.canSend,
                canSendSideChatMessage: model.canSendSideChatMessage,
                canUsePlanMode: model.canUsePlanMode,
                isGoalPursuitEnabled: model.isGoalPursuitEnabled,
                followUpHint: model.followUpHint,
                queuedFollowUps: model.queuedFollowUps,
                mentionResults: model.mentionResults,
                onMentionQueryChanged: { model.updateMentionQuery($0) },
                onMentionSelected: { model.selectMention($0) },
                onSend: { Task { await model.sendDraft() } },
                onSubmitTranscriptUserMessage: { text in
                    guard let threadID = backgroundThreadID else {
                        return .rejected(message: "Select the originating chat before sending this answer.")
                    }
                    return await model.sendTranscriptUserMessage(
                        text, expectedThreadID: threadID, expectedAccountRevision: transcriptAccountRevision
                    )
                },
                onInterrupt: { Task { await model.interrupt() } },
                dictationState: model.dictationSession.state,
                dictationActions: model.voiceSession.isActive
                    ? nil
                    : CodexComposerDictationActions(
                        start: { model.startDictation() },
                        stopAndInsert: { model.stopDictationAndInsert() },
                        stopAndSend: { model.stopDictationAndSend() },
                        retry: { model.retryDictation() },
                        abort: { model.abortDictation() },
                        dismissError: { model.dictationSession.dismissError() }
                    ),
                onStartVoiceChat: model.canStartVoiceChatFromCurrentContext
                    ? { Task { await model.startVoiceChat() } }
                    : nil,
                voiceChatLabel: model.currentThreadID == nil
                    ? "Start new voice chat"
                    : "Start voice chat",
                composerFocusRequest: model.composerFocusRequest,
                onSteerQueuedFollowUp: { clientID in
                    Task { await model.steerQueuedFollowUp(clientID: clientID) }
                },
                onRemoveQueuedFollowUp: { clientID in
                    Task { await model.removeQueuedFollowUp(clientID: clientID) }
                },
                onEditQueuedFollowUp: { clientID in
                    Task { await model.editQueuedFollowUp(clientID: clientID) }
                },
                onSendSideChatMessage: { Task { await model.sendSideChatDraft() } },
                onInterruptSideChatMessage: { Task { await model.interruptSideChat() } },
                onComposerAddMenuRoute: { model.handleComposerAddMenuRoute($0) },
                onComposerChipClear: { model.clearComposerChip($0) },
                onFilesDropped: { [threadID = model.currentThreadID] urls in
                    model.addReferencedFileURLs(urls, to: threadID)
                },
                onOpenThread: { reference in
                    Task { await model.openThreadReference(reference) }
                },
                onStartReview: { target in
                    Task { await model.startCodeReview(target) }
                },
                onOpenMCPDetails: { isMCPStatusSheetPresented = true },
                onRefreshMCPServers: { Task { await model.refreshMCPServers() } },
                onToggleSidebar: collapsePinnedSidebar,
                onDisconnect: { Task { await model.disconnect() } },
                onSlashCommandSelected: { command in
                    model.handleSlashCommand(
                        command,
                        presentStatus: { isStatusSheetPresented = true },
                        presentMCPStatus: { isMCPStatusSheetPresented = true }
                    )
                },
                approvalPrompts: model.approvalPrompts,
                onResolveApproval: { id, approved in
                    model.resolveApprovalPrompt(id: id, approved: approved)
                },
                showsComposer: !isCurrentVoiceTask,
                bottomAccessory: bottomAccessory,
                supplementalTranscriptTurns: supplementalVoicePresentation.turns,
                supplementalTranscriptPresentedAtByTurnID: supplementalVoicePresentation.presentedAtByTurnID
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseWorkspaceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: model.workspacePath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.switchWorkspace(to: url.path) }
    }

    private func addProjectSourceFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(
            fileURLWithPath: projectSourceFoldersDraft.first ?? model.workspacePath
        )
        guard panel.runModal() == .OK else { return }
        projectSourceFoldersDraft = CodexProjectSummary.normalizedSourceFolders(
            projectSourceFoldersDraft + panel.urls.map(\.path)
        )
    }

    private func handleCommandPaletteAction(_ action: CodexCommandPaletteAction) {
        switch action {
        case .newChat:
            Task { await model.startNewChat() }
        case .openChat:
            model.selectAppRoute(.chat)
        case .openPlugins:
            model.selectAppRoute(.plugins)
        case .openAutomations:
            model.selectAppRoute(.automations)
        case .openSettings:
            model.selectAppRoute(.settingsAbout)
        case .openSideChat:
            model.openSideChat()
        case .openReviewPanel:
            if let review = model.gitReviewSession {
                model.workspacePanelState.workspaceTabs.open(
                    CodexReviewWorkspaceTabAdapter(
                        workspaceURL: URL(fileURLWithPath: model.workspacePath),
                        session: review,
                        onStartReview: { target in
                            Task { await model.startCodeReview(target) }
                        }
                    ),
                    from: .commandMenu
                )
            } else {
            }
        case .openMCPDetails:
            isMCPStatusSheetPresented = true
        case .refreshSkills:
            model.refreshSlashCommandsFromPalette()
        case .configureModel:
            model.selectAppRoute(.chat)
            isModelMenuPresented = true
        case .enableGoalPursuit:
            model.selectAppRoute(.chat)
            model.setGoalPursuitEnabled(true)
            focusComposerRequest = true
        case .quitApp:
            NSApplication.shared.terminate(nil)
        }
    }

    private var currentChatActionHandlers: CodexChatActionHandlers {
        guard model.currentThreadID != nil else {
            return CodexChatActionHandlers()
        }
        return CodexChatActionHandlers(
            pinChat: { model.pinCurrentChat() },
            renameChat: {
                renameDraft = model.currentChatTitle
                isRenameSheetPresented = true
            },
            archiveChat: { Task { await model.archiveCurrentChat() } },
            openSideChat: { model.openSideChat() },
            copyChat: { model.copyChatTranscript() },
            forkChat: { Task { await model.forkCurrentChat() } },
            addAutomation: { model.addAutomationForCurrentChat() }
        )
    }
}

private struct RenameChatSheet: View {
    @Environment(\.codexAgentTheme) private var theme

    let title: String
    let placeholder: String
    @Binding var name: String
    let onCancel: () -> Void
    let onSave: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(theme.fonts.sheetTitle)
                .foregroundStyle(theme.colors.textPrimary)

            TextField(placeholder, text: $name)
                .textFieldStyle(.plain)
                .font(theme.fonts.chat)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(theme.colors.surfaceElevated.opacity(0.82), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                        .stroke(theme.colors.border, lineWidth: 1)
                )
                .focused($isFocused)
                .onSubmit(onSave)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(theme.spacing.sheetPadding)
        .frame(width: 360)
        .onAppear { isFocused = true }
    }
}

private struct EditProjectSheet: View {
    @Environment(\.codexAgentTheme) private var theme

    @Binding var name: String
    @Binding var sourceFolders: [String]
    let onAddFolders: () -> Void
    let onRemoveProject: () -> Void
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.sectionGap) {
            HStack {
                Text("Edit project")
                    .font(theme.fonts.routeTitle)
                    .foregroundStyle(theme.colors.textPrimary)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(theme.fonts.chat)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }

            HStack(spacing: 0) {
                Image(systemName: "folder")
                    .foregroundStyle(theme.colors.textSecondary)
                    .frame(width: 44)
                Divider()
                TextField("Project name", text: $name)
                    .textFieldStyle(.plain)
                    .font(theme.fonts.chat)
                    .padding(.horizontal, 14)
            }
            .frame(height: 34)
            .background(
                theme.colors.surfaceElevated.opacity(0.55),
                in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                    .stroke(theme.colors.border, lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 10) {
                Text(sourceFolders.count == 1 ? "Source folder" : "Source folders")
                    .font(theme.fonts.label)
                    .foregroundStyle(theme.colors.textPrimary)

                VStack(spacing: 0) {
                    ForEach(Array(sourceFolders.enumerated()), id: \.element) { index, path in
                        sourceFolderRow(path: path, index: index)
                        if index < sourceFolders.count - 1 {
                            Divider()
                        }
                    }
                    if !sourceFolders.isEmpty {
                        Divider()
                    }
                    Button(action: onAddFolders) {
                        Label("Add folder", systemImage: "folder.badge.plus")
                            .font(theme.fonts.chat)
                            .foregroundStyle(theme.colors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                    }
                    .buttonStyle(.plain)
                }
                .background(
                    theme.colors.surfaceElevated.opacity(0.30),
                    in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                        .stroke(theme.colors.border.opacity(0.8), lineWidth: 1)
                )
            }

            Text("Codex runs in the Primary folder. Every source folder is available to the task.")
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textTertiary)

            HStack {
                Button("Remove project", role: .destructive, action: onRemoveProject)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                Button("Save", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || sourceFolders.isEmpty
                    )
            }
        }
        .padding(theme.spacing.sheetPadding)
        .frame(width: 560)
    }

    private func sourceFolderRow(path: String, index: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .foregroundStyle(theme.colors.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(theme.fonts.chat)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
                Text(CodexPathFormatter.abbreviatingHome(path))
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            if index == 0 {
                Text("Primary")
                    .font(theme.fonts.caption.weight(.semibold))
                    .foregroundStyle(theme.colors.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.colors.surfaceSunken, in: Capsule())
            } else {
                Button("Make primary") {
                    sourceFolders.remove(at: index)
                    sourceFolders.insert(path, at: 0)
                }
                .buttonStyle(.plain)
                .font(theme.fonts.caption.weight(.semibold))
            }
            Button {
                sourceFolders.remove(at: index)
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(sourceFolders.count == 1)
            .accessibilityLabel("Remove \(URL(fileURLWithPath: path).lastPathComponent)")
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
    }
}
