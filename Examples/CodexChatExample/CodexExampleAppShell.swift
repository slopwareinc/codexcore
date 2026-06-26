import AppKit
import SwiftUI
import CodexCore
import CodexCoreUI

struct CodexExampleAppShell: View {
    @Bindable var model: CodexChatModel
    @State private var isRenameSheetPresented = false
    @State private var isMCPStatusSheetPresented = false
    @State private var renameDraft = ""

    var body: some View {
        let sidebarSnapshot = model.sidebarSnapshot

        HStack(spacing: 0) {
            CodexExampleProjectSidebar(
                serverName: model.serverName,
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
                onProjectActions: { _ in },
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
        .overlay(alignment: .topTrailing) {
            if !model.approvalPrompts.isEmpty || !model.interactivePrompts.isEmpty || !model.currentPlan.isEmpty || model.currentDiff != nil {
                VStack(alignment: .trailing, spacing: 10) {
                    if !model.approvalPrompts.isEmpty {
                        ApprovalRequestsPanel(
                            prompts: model.approvalPrompts,
                            onApprove: { id in model.resolveApprovalPrompt(id: id, approved: true) },
                            onDeny: { id in model.resolveApprovalPrompt(id: id, approved: false) }
                        )
                    }

                    if !model.interactivePrompts.isEmpty {
                        InteractivePromptsPanel(
                            prompts: model.interactivePrompts,
                            onSubmit: { id, answers in model.submitInteractivePrompt(id: id, answers: answers) },
                            onAccept: { id in model.acceptInteractivePrompt(id: id) },
                            onDecline: { id in model.declineInteractivePrompt(id: id) }
                        )
                    }

                    if !model.currentPlan.isEmpty || model.currentDiff != nil {
                        TurnPlanPanel(
                            steps: model.currentPlan,
                            explanation: model.currentPlanExplanation,
                            diff: model.currentDiff
                        )
                    }
                }
                .codexAgentTheme(model.themePreset.theme)
                .padding(.top, 54)
                .padding(.trailing, 18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay {
            if model.sidebarSnapshot.isSearchOverlayPresented {
                CommandPaletteOverlay(
                    model: model,
                    onClose: { model.dismissSearchRoute() },
                    onSelectChat: { result in
                        Task { await model.resumeSearchResult(result) }
                    },
                    onSelectCommand: handleCommandPaletteAction
                )
                .codexAgentTheme(model.themePreset.theme)
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
            .codexAgentTheme(model.themePreset.theme)
        }
        .sheet(isPresented: $isMCPStatusSheetPresented) {
            MCPStatusSheet(
                model: model,
                onClose: { isMCPStatusSheetPresented = false },
                onRefresh: { Task { await model.refreshMCPServers() } }
            )
            .codexAgentTheme(model.themePreset.theme)
        }
    }

    @ViewBuilder
    private func routeContent(proxy: GeometryProxy, selectedRoute: CodexAppRoute) -> some View {
        switch selectedRoute {
        case .chat, .search:
            chatWorkspace(proxy: proxy)
        case .plugins:
            PluginsRouteView(
                model: model,
                onRefresh: { Task { await model.refreshPlugins() } },
                onAction: { model.performPluginCatalogAction($0) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .codexAgentTheme(model.themePreset.theme)
        case .automations:
            AutomationsRouteView(onAction: model.performAutomationRouteAction)
                .codexAgentTheme(model.themePreset.theme)
        case .codexMobile:
            CodexMobileRouteView(
                state: model.mobileRouteSession.state,
                onRefreshStatus: { Task { await model.refreshMobileRemoteControlStatus() } },
                onGetStarted: model.openMobilePermissionGate,
                onCancelPermissionGate: model.cancelMobilePermissionGate,
                onAllow: model.allowMobileRemoteControlBoundary
            )
                .codexAgentTheme(model.themePreset.theme)
        case .settingsAbout:
            SettingsAboutRouteView(metadata: CodexAboutMetadata(bundle: .main, serverName: model.serverName))
                .codexAgentTheme(model.themePreset.theme)
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
                rateLimitBannerMessage: model.rateLimitBannerMessage,
                workspaceSummary: model.workspaceSummaryContext,
                gitReviewSession: model.gitReviewSession,
                showsSidebarToggle: true,
                isSidebarVisible: !model.sidebarSnapshot.isCollapsed,
                chatActions: currentChatActionHandlers,
                approvalOptions: model.approvalOptions,
                modelOptions: model.modelOptions,
                slashCommands: model.slashCommands,
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
                onComposerDictationRoute: { model.handleComposerDictationRoute($0) },
                onComposerChipClear: { model.clearComposerChip($0) },
                onEnvironmentHandoffCompletion: { model.handleWorktreeHandoffCompletion($0) },
                onCloseTranscriptMessage: { model.dismissTranscriptMessage($0) },
                onOpenMCPDetails: { isMCPStatusSheetPresented = true },
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
            addAutomation: { model.addAutomationForCurrentChat() },
            openInNewWindow: { model.openCurrentChatInNewWindow() }
        )
    }
}

private struct AutomationsRouteView: View {
    @Environment(\.codexAgentTheme) private var theme

    let onAction: (CodexAutomationRouteAction) -> Void
    @State private var session = CodexAutomationRouteSession()

    private var state: CodexAutomationRouteState {
        session.state
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.colors.border)
            VStack(alignment: .leading, spacing: 24) {
                segmentedControls
                if state.showsEmptyState {
                    emptyTemplates
                } else {
                    automationRows
                }
            }
            .padding(24)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.colors.surface)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: CodexAppRoute.automations.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.colors.textSecondary)
                .frame(width: 24, height: 28)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(state.headerTitle)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(theme.colors.textPrimary)
                    Button {
                        onAction(.learnMore)
                    } label: {
                        Text(state.learnMoreTitle)
                            .font(theme.fonts.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.colors.accent)
                    .accessibilityLabel(state.learnMoreTitle)
                }
                Text(state.description)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
            Spacer(minLength: 0)
            Button {} label: {
                Label(state.newAutomationOptionsTitle, systemImage: "ellipsis.circle")
            }
            .buttonStyle(.bordered)
            .disabled(true)
            .help(state.newAutomationOptionsTitle)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var segmentedControls: some View {
        HStack(spacing: 8) {
            ForEach(CodexAutomationRouteMode.allCases) { mode in
                Button {
                    selectMode(mode)
                } label: {
                    Text(mode.title)
                        .font(theme.fonts.caption.weight(.semibold))
                        .foregroundStyle(state.mode == mode ? theme.colors.textPrimary : theme.colors.textSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(
                            state.mode == mode ? theme.colors.surfaceElevated.opacity(0.9) : theme.colors.surfaceSunken.opacity(0.42),
                            in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                                .stroke(theme.colors.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.title)
            }
        }
    }

    private var emptyTemplates: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.emptyTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.colors.textPrimary)

            HStack(spacing: 10) {
                ForEach(state.templates) { template in
                    AutomationTemplateButton(template: template) {
                        perform(.template(template))
                    }
                }
            }
        }
    }

    private var automationRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(state.automations) { automation in
                HStack {
                    Text(automation.title)
                        .font(theme.fonts.chat.weight(.semibold))
                    Spacer()
                    Text(automation.statusLabel)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                }
                .padding(12)
                .background(theme.colors.surfaceElevated.opacity(0.66), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
            }
        }
    }

    private func selectMode(_ mode: CodexAutomationRouteMode) {
        switch mode {
        case .viewTemplates:
            session.viewTemplates()
        case .createViaChat:
            perform(.createViaChat)
        }
    }

    private func perform(_ action: CodexAutomationRouteAction) {
        _ = session.perform(action)
        onAction(action)
    }
}

private struct AutomationTemplateButton: View {
    @Environment(\.codexAgentTheme) private var theme

    let template: CodexAutomationTemplate
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: template.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.colors.textSecondary)
                Text(template.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(template.isDraftBacked ? theme.colors.textPrimary : theme.colors.textTertiary)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(width: 156, height: 82, alignment: .leading)
            .background(theme.colors.surfaceElevated.opacity(0.72), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                    .stroke(theme.colors.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!template.isDraftBacked)
        .help(template.title)
    }
}

private struct CodexMobileRouteView: View {
    @Environment(\.codexAgentTheme) private var theme

    let state: CodexMobileRouteState
    let onRefreshStatus: () -> Void
    let onGetStarted: () -> Void
    let onCancelPermissionGate: () -> Void
    let onAllow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(state.title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Text(state.subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.colors.textSecondary)
            }

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    MobileBenefitRow(systemImage: "arrow.triangle.2.circlepath", title: state.benefits[0])
                    MobileBenefitRow(systemImage: "bell", title: state.benefits[1])
                    MobileBenefitRow(systemImage: "sparkles", title: state.benefits[2])

                    Text(state.warning)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.warning)
                        .fixedSize(horizontal: false, vertical: true)

                    mobileStatusCard

                    HStack(spacing: 10) {
                        Button(action: onGetStarted) {
                            Text(state.getStartedTitle)
                        }
                        .buttonStyle(.borderedProminent)
                        Button(action: onRefreshStatus) {
                            Text("Refresh status")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)

                PhoneMockView()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.colors.surface)
        .onAppear(perform: onRefreshStatus)
        .sheet(isPresented: Binding(
            get: { state.isPermissionGatePresented },
            set: { presented in
                if !presented { onCancelPermissionGate() }
            }
        )) {
            MobilePermissionGate(state: state, onCancel: onCancelPermissionGate, onAllow: onAllow)
                .codexAgentTheme(theme)
        }
    }

    private var mobileStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Remote control")
                    .font(theme.fonts.caption.weight(.semibold))
                    .foregroundStyle(theme.colors.textTertiary)
                Text(state.status.statusLine)
                    .font(theme.fonts.caption)
                    .foregroundStyle(state.status.kind == .error ? theme.colors.warning : theme.colors.textSecondary)
            }
            Text(state.pairing.statusLabel)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)
            ForEach(state.clients) { client in
                Text("\(client.displayName) · \(client.platformLabel)")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
        }
        .padding(12)
        .background(theme.colors.surfaceElevated.opacity(0.58), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
    }
}

private struct MobileBenefitRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let systemImage: String
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.colors.accent)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.colors.textPrimary)
        }
    }
}

private struct PhoneMockView: View {
    @Environment(\.codexAgentTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(theme.colors.success)
                    .frame(width: 8, height: 8)
                Text("Codex")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(theme.colors.textPrimary)

            VStack(alignment: .leading, spacing: 7) {
                Text("Projects")
                    .font(theme.fonts.caption.weight(.semibold))
                    .foregroundStyle(theme.colors.textTertiary)
                Text("CodexCore")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.colors.textPrimary)
                Text("Chats")
                    .font(theme.fonts.caption.weight(.semibold))
                    .foregroundStyle(theme.colors.textTertiary)
                Text("Continue release plan")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.colors.textSecondary)
            }
        }
        .padding(18)
        .frame(width: 190, height: 300, alignment: .topLeading)
        .background(theme.colors.surfaceElevated.opacity(0.82), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
    }
}

private struct MobilePermissionGate: View {
    @Environment(\.codexAgentTheme) private var theme

    let state: CodexMobileRouteState
    let onCancel: () -> Void
    let onAllow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(state.permissionTitle)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.colors.textPrimary)
            Text(state.permissionQuestion)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.colors.textPrimary)
            Text(state.permissionDetail)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Allow", action: onAllow)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(theme.colors.surface)
    }
}

private struct SettingsAboutRouteView: View {
    @Environment(\.codexAgentTheme) private var theme

    let metadata: CodexAboutMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: CodexAppRoute.settingsAbout.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.colors.textSecondary)
                Text("Settings")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("About Codex")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Text(metadata.appName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.colors.textSecondary)
                Text(metadata.versionLine)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                Text(metadata.copyright)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
            }
            .padding(14)
            .background(theme.colors.surfaceElevated.opacity(0.72), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                    .stroke(theme.colors.border, lineWidth: 1)
            )

            Text("Detailed Settings/Profile tabs were not reachable in current-app evidence, so this route is limited to About and app boundary information.")
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)

            if let serverName = metadata.serverName {
                Text(serverName)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.colors.surface)
    }
}

private struct TurnPlanPanel: View {
    @Environment(\.codexAgentTheme) private var theme

    let steps: [TurnPlanStep]
    let explanation: String?
    let diff: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.colors.accent)
                Text("Plan")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Spacer(minLength: 0)
                if !steps.isEmpty {
                    Text("\(steps.filter { $0.status == .completed }.count)/\(steps.count)")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                }
            }

            if let explanation, !explanation.isEmpty {
                Text(explanation)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                    .lineLimit(2)
            }

            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: statusImage(step.status))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(statusColor(step.status))
                        .frame(width: 16)
                    Text(step.step)
                        .font(theme.fonts.caption)
                        .foregroundStyle(step.status == .completed ? theme.colors.textTertiary : theme.colors.textPrimary)
                        .strikethrough(step.status == .completed, color: theme.colors.textTertiary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }

            if let diff, !diff.isEmpty {
                Divider().overlay(theme.colors.border)
                HStack(spacing: 8) {
                    Image(systemName: "plusminus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.colors.textSecondary)
                        .frame(width: 16)
                    Text(diffSummary(diff))
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diff, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.colors.textTertiary)
                    .help("Copy diff")
                }
            }
        }
        .padding(12)
        .frame(width: 360)
        .background(theme.colors.surfaceElevated.opacity(0.96), in: RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 12)
    }

    private func statusImage(_ status: TurnPlanStepStatus) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "circle.dotted.circle"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private func statusColor(_ status: TurnPlanStepStatus) -> Color {
        switch status {
        case .pending: return theme.colors.textTertiary
        case .inProgress: return theme.colors.accent
        case .completed: return theme.colors.success
        }
    }

    private func diffSummary(_ diff: String) -> String {
        let files = diff.components(separatedBy: "diff --git").count - 1
        let added = diff.split(separator: "\n").filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
        let removed = diff.split(separator: "\n").filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
        if files > 0 {
            return "\(files) file(s) · +\(added) −\(removed)"
        }
        return "+\(added) −\(removed)"
    }
}

private struct ApprovalRequestsPanel: View {
    @Environment(\.codexAgentTheme) private var theme

    let prompts: [CodexApprovalPrompt]
    let onApprove: (String) -> Void
    let onDeny: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.colors.warning)
                Text("Approval needed")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Spacer(minLength: 0)
                Text("\(prompts.count)")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
            }

            ForEach(prompts.prefix(3)) { prompt in
                ApprovalPromptRow(prompt: prompt, onApprove: onApprove, onDeny: onDeny)
            }
        }
        .padding(12)
        .frame(width: 360)
        .background(theme.colors.surfaceElevated.opacity(0.96), in: RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 12)
    }
}

private struct ApprovalPromptRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let prompt: CodexApprovalPrompt
    let onApprove: (String) -> Void
    let onDeny: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: prompt.kind.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.colors.textSecondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.colors.textPrimary)
                        .lineLimit(1)
                    Text(prompt.detail)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            if let primary = prompt.primaryValue, !primary.isEmpty {
                Text(primary)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.colors.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
            }

            if let secondary = prompt.secondaryValue, !secondary.isEmpty {
                Text(secondary)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 8) {
                Button {
                    onDeny(prompt.id)
                } label: {
                    Label("Deny", systemImage: "xmark")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Deny")

                Spacer(minLength: 0)

                Button {
                    onApprove(prompt.id)
                } label: {
                    Label("Approve", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .help("Approve")
            }
        }
        .padding(10)
        .background(theme.colors.surface.opacity(0.58), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
    }
}

private struct InteractivePromptsPanel: View {
    @Environment(\.codexAgentTheme) private var theme

    let prompts: [CodexInteractivePrompt]
    let onSubmit: (String, [String: String]) -> Void
    let onAccept: (String) -> Void
    let onDecline: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.colors.accent)
                Text("Input needed")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Spacer(minLength: 0)
                Text("\(prompts.count)")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
            }

            ForEach(prompts.prefix(3)) { prompt in
                InteractivePromptRow(
                    prompt: prompt,
                    onSubmit: onSubmit,
                    onAccept: onAccept,
                    onDecline: onDecline
                )
            }
        }
        .padding(12)
        .frame(width: 360)
        .background(theme.colors.surfaceElevated.opacity(0.96), in: RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 12)
    }
}

private struct InteractivePromptRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let prompt: CodexInteractivePrompt
    let onSubmit: (String, [String: String]) -> Void
    let onAccept: (String) -> Void
    let onDecline: (String) -> Void
    @State private var answers: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: prompt.kind.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.colors.textSecondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.colors.textPrimary)
                        .lineLimit(1)
                    Text(prompt.detail)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
            }

            if prompt.kind == .userInput {
                ForEach(prompt.questions) { question in
                    questionEditor(question)
                }
            } else if let serverName = prompt.serverName {
                Text(serverName)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.colors.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
            }

            HStack(spacing: 8) {
                Button {
                    onDecline(prompt.id)
                } label: {
                    Label(prompt.kind == .userInput ? "Cancel" : "Decline", systemImage: "xmark")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer(minLength: 0)

                Button {
                    if prompt.kind == .userInput {
                        onSubmit(prompt.id, answers)
                    } else {
                        onAccept(prompt.id)
                    }
                } label: {
                    Label(prompt.kind == .userInput ? "Submit" : "Allow", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(prompt.kind == .userInput && !hasRequiredAnswers)
            }
        }
        .padding(10)
        .background(theme.colors.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
    }

    private var hasRequiredAnswers: Bool {
        guard !prompt.questions.isEmpty else { return true }
        return prompt.questions.allSatisfy { question in
            !(answers[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    @ViewBuilder
    private func questionEditor(_ question: CodexUserInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header = question.header {
                Text(header)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
            }
            Text(question.question)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)
                .lineLimit(3)

            if !question.options.isEmpty {
                FlexibleOptionButtons(
                    options: question.options,
                    selectedAnswer: answers[question.id],
                    onSelect: { answers[question.id] = $0 }
                )
            }

            if question.isSecret {
                SecureField("Answer", text: answerBinding(for: question.id))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            } else if question.isOtherAllowed || question.options.isEmpty {
                TextField("Answer", text: answerBinding(for: question.id))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(theme.colors.surfaceElevated.opacity(0.52), in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
    }

    private func answerBinding(for id: String) -> Binding<String> {
        Binding(
            get: { answers[id] ?? "" },
            set: { answers[id] = $0 }
        )
    }
}

private struct FlexibleOptionButtons: View {
    @Environment(\.codexAgentTheme) private var theme

    let options: [CodexUserInputOption]
    let selectedAnswer: String?
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(options, id: \.label) { option in
                Button {
                    onSelect(option.label)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: selectedAnswer == option.label ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11, weight: .semibold))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.colors.textPrimary)
                                .lineLimit(1)
                            if let description = option.description {
                                Text(description)
                                    .font(theme.fonts.caption)
                                    .foregroundStyle(theme.colors.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .background(
                    (selectedAnswer == option.label ? theme.colors.accent.opacity(0.16) : theme.colors.surface.opacity(0.72)),
                    in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                        .stroke(selectedAnswer == option.label ? theme.colors.accent.opacity(0.5) : theme.colors.border, lineWidth: 1)
                )
            }
        }
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
