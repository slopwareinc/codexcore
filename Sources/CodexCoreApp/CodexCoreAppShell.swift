import SwiftUI
import AppKit
import CodexCore
import CodexCoreUI

struct CodexCoreAppShell: View {
    @Bindable var model: CodexCoreAppModel
    @State private var isRenameSheetPresented = false
    @State private var isMCPStatusSheetPresented = false
    @State private var renameDraft = ""
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
                        .shadow(color: .black.opacity(0.34), radius: 24, x: 8, y: 0)
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
        .frame(minWidth: 600, minHeight: 540)
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: sidebarSnapshot.isCollapsed) { _, isCollapsed in
            if !isCollapsed {
                sidebarOverlaySession.dismissImmediately()
            }
        }
        .onExitCommand {
            sidebarOverlaySession.dismissImmediately()
        }
        .overlay(alignment: .topTrailing) {
            if !model.approvalPrompts.isEmpty || !model.interactivePrompts.isEmpty || !model.currentPlan.isEmpty || model.currentDiff != nil {
                VStack(alignment: .trailing, spacing: 10) {
                    if !model.approvalPrompts.isEmpty {
                        CodexApprovalRequestsPanel(
                            prompts: model.approvalPrompts,
                            onDecision: { id, decision in
                                model.resolveApprovalPrompt(id: id, decision: decision)
                            }
                        )
                    }

                    if !model.interactivePrompts.isEmpty {
                        CodexInteractivePromptsPanel(
                            prompts: model.interactivePrompts,
                            onSubmit: { id, answers in model.submitInteractivePrompt(id: id, answers: answers) },
                            onAccept: { id in model.acceptInteractivePrompt(id: id) },
                            onDecline: { id in model.declineInteractivePrompt(id: id) }
                        )
                    }

                    if !model.currentPlan.isEmpty || model.currentDiff != nil {
                        CodexTurnPlanPanel(
                            steps: model.currentPlan,
                            explanation: model.currentPlanExplanation,
                            diff: model.currentDiff,
                            onCopyDiff: { diff in model.copyText(diff) }
                        )
                    }
                }
                .codexAgentTheme(model.theme)
                .padding(.top, 54)
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
                    onSelectCommand: handleCommandPaletteAction
                )
                .codexAgentTheme(model.theme)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .sheet(isPresented: $isRenameSheetPresented) {
            RenameChatSheet(
                name: $renameDraft,
                onCancel: { isRenameSheetPresented = false },
                onSave: {
                    isRenameSheetPresented = false
                    Task { await model.renameCurrentChat(to: renameDraft) }
                }
            )
            .codexAgentTheme(model.theme)
        }
        .sheet(isPresented: $isMCPStatusSheetPresented) {
            CodexMCPStatusSheet(
                servers: model.mcpServers,
                isLoading: model.isLoadingMCPServers,
                errorMessage: model.mcpErrorMessage,
                onClose: { isMCPStatusSheetPresented = false },
                onRefresh: { Task { await model.refreshMCPServers() } }
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
            onStartProjectChat: { path in Task { await model.startNewChat(inProject: path) } },
            onSelectProject: { path in Task { await model.selectSidebarProject(path) } },
            onOpenFolder: { chooseWorkspaceFolder() },
            onSelectChat: { chat in Task { await model.selectSidebarChat(chat) } },
            onTogglePinChat: { chat in model.toggleSidebarChatPin(chat) },
            onArchiveChat: { chat in Task { await model.archiveSidebarChat(chat) } }
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

    @ViewBuilder
    private func routeContent(proxy: GeometryProxy, selectedRoute: CodexAppRoute) -> some View {
        switch selectedRoute {
        case .chat, .search:
            chatWorkspace(proxy: proxy)
        case .plugins:
            CodexPluginRouteView(
                plugins: model.plugins,
                skills: model.skills,
                mcpServers: model.mcpServers,
                isLoadingPlugins: model.isLoadingPlugins,
                isLoadingSkills: model.isLoadingSkills,
                pluginErrorMessage: model.pluginErrorMessage,
                skillErrorMessage: model.skillErrorMessage,
                pluginLoadErrors: model.pluginLoadErrors,
                launcherTarget: model.pluginLauncherTarget,
                onRefresh: { Task { await model.refreshPlugins() } },
                onAction: { model.performPluginCatalogAction($0) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .codexAgentTheme(model.theme)
        case .automations:
            CodexAutomationRouteView(onAction: model.performAutomationRouteAction)
                .codexAgentTheme(model.theme)
        case .codexMobile:
            CodexMobileRouteView(
                state: model.mobileRouteSession.state,
                onRefreshStatus: { Task { await model.refreshMobileRemoteControlStatus() } },
                onGetStarted: model.openMobilePermissionGate,
                onCancelPermissionGate: model.cancelMobilePermissionGate,
                onAllow: model.allowMobileRemoteControlBoundary
            )
                .codexAgentTheme(model.theme)
        case .settingsAbout:
            CodexSettingsAboutRouteView(
                metadata: CodexAboutMetadata(
                    bundle: .main,
                    serverName: model.serverName,
                    fallbackAppName: "Codex",
                    fallbackCopyright: "© OpenAI"
                ),
                accountSummary: model.accountMenuSummary,
                appearanceSettings: $model.appearanceSettings,
                sidebarFontSize: $model.sidebarFontSize,
                sidebarFontSizeRange: CodexSidebarFontSizeStorage.fontSizeRange,
                approvalSelection: $model.approvalSelection,
                approvalOptions: model.approvalOptions,
                modelSelection: $model.modelSelection,
                modelOptions: model.modelOptions,
                reasoningSelection: $model.reasoningSelection,
                isBottomPanelVisible: $model.isBottomTerminalVisible,
                gitSettings: $model.gitSettings,
                newThreadHistoryMode: $model.newThreadHistoryMode,
                mcpServers: model.mcpServers,
                isLoadingMCPServers: model.isLoadingMCPServers,
                onBackToApp: { model.selectAppRoute(.chat) }
            )
                .codexAgentTheme(model.theme)
        }
    }

    private func chatWorkspace(proxy: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            CodexChatWorkspaceView(
                presentationStore: model.runtimeSession.presentationStore,
                lifecycleEvents: model.lifecycleEvents,
                sideChat: model.sideChat,
                subagents: model.subagents,
                activities: model.activities,
                connectionState: model.connectionState,
                workspacePath: model.workspacePath,
                chatTitle: model.currentChatTitle,
                currentThreadID: model.currentThreadID,
                panel: model.workspacePanelState,
                mountedPanels: model.mountedWorkspacePanels,
                rateLimitBannerMessage: model.rateLimitBannerMessage,
                workspaceSummary: model.workspaceSummaryContext,
                gitReviewSession: model.gitReviewSession,
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
                reasoningSelection: $model.reasoningSelection,
                draft: $model.draft,
                referencedFiles: $model.referencedFiles,
                sideChatDraft: $model.sideChatDraft,
                isSending: model.isSending,
                isSideChatSending: model.isSideChatSending,
                canSend: model.canSend,
                canSendSideChatMessage: model.canSendSideChatMessage,
                canUsePlanMode: model.canUsePlanMode,
                isGoalPursuitEnabled: model.isGoalPursuitEnabled,
                followUpHint: model.followUpHint,
                mentionResults: model.mentionResults,
                onMentionQueryChanged: { model.updateMentionQuery($0) },
                onMentionSelected: { model.selectMention($0) },
                onSend: { Task { await model.sendDraft() } },
                onInterrupt: { Task { await model.interrupt() } },
                onSendSideChatMessage: { Task { await model.sendSideChatDraft() } },
                onInterruptSideChatMessage: { Task { await model.interruptSideChat() } },
                onComposerAddMenuRoute: { model.handleComposerAddMenuRoute($0) },
                onComposerChipClear: { model.clearComposerChip($0) },
                onFilesDropped: { [threadID = model.currentThreadID] urls in
                    model.addReferencedFileURLs(urls, to: threadID)
                },
                onEnvironmentHandoffCompletion: { model.handleWorktreeHandoffCompletion($0) },
                onCloseTranscriptMessage: { model.dismissTranscriptMessage($0) },
                onOpenMCPDetails: { isMCPStatusSheetPresented = true },
                onRefreshMCPServers: { Task { await model.refreshMCPServers() } },
                onToggleSidebar: collapsePinnedSidebar,
                onDisconnect: { Task { await model.disconnect() } },
                onSlashCommandSelected: { command in
                    model.handleSlashCommand(command) {
                        isMCPStatusSheetPresented = true
                    }
                },
                approvalPrompts: model.approvalPrompts,
                onResolveApproval: { id, approved in model.resolveApprovalPrompt(id: id, approved: approved) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.isBottomTerminalVisible {
                CodexBottomTerminalPanel(
                    model: model,
                    maxHeight: max(180, proxy.size.height - 180)
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.isBottomTerminalVisible)
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
        case .openMobile:
            model.selectAppRoute(.codexMobile)
        case .openSettings:
            model.selectAppRoute(.settingsAbout)
        case .openSideChat:
            model.openSideChat()
        case .openReviewPanel:
            model.appendPaletteNotice(title: "Review panel", detail: "Review opens from the Changes panel when a diff is available.")
        case .openMCPDetails:
            isMCPStatusSheetPresented = true
        case .refreshSkills:
            model.refreshSlashCommandsFromPalette()
        case .configureModel:
            model.appendPaletteNotice(title: "Model controls", detail: "Use the model menu in the composer.")
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

    @Binding var name: String
    let onCancel: () -> Void
    let onSave: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename chat")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.colors.textPrimary)

            TextField("Chat name", text: $name)
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
        .padding(20)
        .frame(width: 360)
        .background(theme.colors.surface)
        .onAppear { isFocused = true }
    }
}
