import SwiftUI
import AppKit
import CodexCore
import CodexCoreUI

struct CodexCoreAppShell: View {
    @Bindable var model: CodexCoreAppModel
    @State private var isRenameSheetPresented = false
    @State private var isMCPStatusSheetPresented = false
    @State private var renameDraft = ""

    var body: some View {
        let sidebarSnapshot = model.sidebarSnapshot

        HStack(spacing: 0) {
            CodexProjectSidebar(
                serverName: model.serverName,
                accountSummary: model.accountMenuSummary,
                isThreadReady: model.isThreadReady,
                snapshot: sidebarSnapshot,
                onNewChat: { Task { await model.startNewChat() } },
                onOpenSearch: { model.selectAppRoute(.search) },
                onSelectRoute: { model.selectAppRoute($0) },
                onToggleCollapsed: {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                        model.toggleSidebarCollapsed()
                    }
                },
                onToggleProject: { model.toggleSidebarProject($0) },
                onStartProjectChat: { path in Task { await model.startNewChat(inProject: path) } },
                onSelectProject: { path in Task { await model.selectSidebarProject(path) } },
                onOpenFolder: { chooseWorkspaceFolder() },
                onSelectChat: { chat in Task { await model.selectSidebarChat(chat) } },
                onTogglePinChat: { chat in model.toggleSidebarChatPin(chat) },
                onArchiveChat: { chat in Task { await model.archiveSidebarChat(chat) } }
            )
            .layoutPriority(0)
            .transition(.move(edge: .leading).combined(with: .opacity))

            GeometryReader { proxy in
                routeContent(proxy: proxy, selectedRoute: sidebarSnapshot.selectedRoute)
            }
            .frame(minWidth: 620)
            .layoutPriority(1)
        }
        .frame(minWidth: sidebarSnapshot.isCollapsed ? 760 : 980, minHeight: 620)
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .topTrailing) {
            if !model.approvalPrompts.isEmpty || !model.interactivePrompts.isEmpty || !model.currentPlan.isEmpty || model.currentDiff != nil {
                VStack(alignment: .trailing, spacing: 10) {
                    if !model.approvalPrompts.isEmpty {
                        CodexApprovalRequestsPanel(
                            prompts: model.approvalPrompts,
                            onApprove: { id in model.resolveApprovalPrompt(id: id, approved: true) },
                            onDeny: { id in model.resolveApprovalPrompt(id: id, approved: false) }
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
                metadata: CodexAboutMetadata(bundle: .main, serverName: model.serverName),
                sidebarFontSize: $model.sidebarFontSize,
                sidebarFontSizeRange: CodexSidebarFontSizeStorage.fontSizeRange
            )
                .codexAgentTheme(model.theme)
        }
    }

    private func chatWorkspace(proxy: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            CodexChatWorkspaceView(
                messages: model.messages,
                lifecycleEvents: model.lifecycleEvents,
                sideChat: model.sideChat,
                subagents: model.subagents,
                activities: model.activities,
                connectionState: model.connectionState,
                workspacePath: model.workspacePath,
                chatTitle: model.currentChatTitle,
                currentThreadID: model.currentThreadID,
                rateLimitBannerMessage: model.rateLimitBannerMessage,
                workspaceSummary: model.workspaceSummaryContext,
                gitReviewSession: model.gitReviewSession,
                showsSidebarToggle: true,
                isSidebarVisible: !model.sidebarSnapshot.isCollapsed,
                isThreadLoading: model.isThreadLoading,
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
                onEnvironmentHandoffCompletion: { model.handleWorktreeHandoffCompletion($0) },
                onCloseTranscriptMessage: { model.dismissTranscriptMessage($0) },
                onOpenMCPDetails: { isMCPStatusSheetPresented = true },
                onRefreshMCPServers: { Task { await model.refreshMCPServers() } },
                onToggleSidebar: {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                        model.toggleSidebarCollapsed()
                    }
                },
                onDisconnect: { Task { await model.disconnect() } },
                onSlashCommandSelected: { command in
                    model.handleSlashCommand(command) {
                        isMCPStatusSheetPresented = true
                    }
                }
            )
            .codexFileChangeUndo { change in
                Task { @MainActor in
                    model.undoFileChange(change)
                }
            }
            .codexFileChangeReview { change in
                Task { @MainActor in
                    model.reviewFileChange(change)
                }
            }
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
