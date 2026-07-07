import SwiftUI
import CodexCore

public struct CodexWorkspaceResponsivePanelState: Equatable, Sendable {
    public var availableWidth: CGFloat

    public init(availableWidth: CGFloat) {
        self.availableWidth = max(0, availableWidth)
    }

    public var usesFloatingSummaryPanel: Bool {
        availableWidth >= 1_040
    }

    public var usesPersistentSidePanel: Bool {
        availableWidth >= 980
    }

    public var usesOverlaySummaryPanel: Bool {
        !usesFloatingSummaryPanel
    }

    public var usesOverlaySidePanel: Bool {
        !usesPersistentSidePanel
    }
}

/// A complete reusable Codex chat workspace: transcript, header, composer, and agent panels.
public struct CodexChatWorkspaceView: View {
    @Environment(\.codexAgentTheme) private var theme

    private let messages: [CodexChatMessage]
    private let lifecycleEvents: [CodexAgentLifecycleEvent]
    private let sideChat: CodexSideChatState?
    private let subagents: [CodexSubagentState]
    private let activities: [CodexActivity]
    private let connectionState: CodexConnectionState
    private let workspacePath: String
    private let chatTitle: String
    private let currentThreadID: String?
    private let rateLimitBannerMessage: String?
    private let workspaceSummary: CodexWorkspaceSummaryContext?
    private let gitReviewSession: CodexGitReviewSession?
    private let showsSidebarToggle: Bool
    private let isSidebarVisible: Bool
    private let isThreadLoading: Bool
    private let chatActions: CodexChatActionHandlers
    private let approvalOptions: [CodexApprovalSelection]
    private let modelOptions: [CodexModelSelection]
    private let slashCommands: [CodexSlashCommand]
    private let mcpServers: [CodexMCPServerStatus]
    private let isLoadingMCPServers: Bool
    private let mcpErrorMessage: String?
    @Binding private var approvalSelection: CodexApprovalSelection
    @Binding private var isPlanModeEnabled: Bool
    @Binding private var modelSelection: CodexModelSelection
    @Binding private var reasoningSelection: CodexReasoningSelection
    @Binding private var draft: String
    @Binding private var sideChatDraft: String
    private let isSending: Bool
    private let isSideChatSending: Bool
    private let canSend: Bool
    private let canSendSideChatMessage: Bool
    private let canUsePlanMode: Bool
    private let isGoalPursuitEnabled: Bool
    private let followUpHint: String?
    private let mentionResults: [FuzzyFileSearchResult]
    private let onMentionQueryChanged: ((String?) -> Void)?
    private let onMentionSelected: ((FuzzyFileSearchResult) -> Void)?
    private let onSend: () -> Void
    private let onInterrupt: () -> Void
    private let onSendSideChatMessage: () -> Void
    private let onInterruptSideChatMessage: () -> Void
    private let onComposerAddMenuRoute: ((CodexComposerAddMenuRoute) -> Void)?
    private let onComposerChipClear: ((CodexComposerChipKind) -> Void)?
    private let onEnvironmentHandoffCompletion: (@MainActor @Sendable (CodexWorktreeHandoffCompletion) -> Void)?
    private let onCloseTranscriptMessage: ((UUID) -> Void)?
    private let onOpenMCPDetails: (() -> Void)?
    private let onRefreshMCPServers: (() -> Void)?
    private let onToggleSidebar: () -> Void
    private let onDisconnect: () -> Void
    private let onPromptSelected: ((String) -> Void)?
    private let onSlashCommandSelected: ((CodexSlashCommand) -> Void)?
    @State private var isAgentPanelOpen = false
    @State private var isSummaryPanelOpen = true
    @State private var isCompactSummaryPanelPresented = false
    @State private var selectedPanelTabID: String?
    @State private var agentPanelWidth: CGFloat = CodexAgentTheme.officialDark.spacing.sidePanelWidth
    @State private var terminalSessions: [CodexTerminalSession] = []
    @State private var browserSessions: [CodexBrowserSession] = []
    @State private var nextTerminalNumber = 1
    @State private var nextBrowserNumber = 1

    public init(
        messages: [CodexChatMessage],
        lifecycleEvents: [CodexAgentLifecycleEvent] = [],
        sideChat: CodexSideChatState? = nil,
        subagents: [CodexSubagentState] = [],
        activities: [CodexActivity],
        connectionState: CodexConnectionState,
        workspacePath: String,
        chatTitle: String = "Codex",
        currentThreadID: String? = nil,
        rateLimitBannerMessage: String? = nil,
        workspaceSummary: CodexWorkspaceSummaryContext? = nil,
        gitReviewSession: CodexGitReviewSession? = nil,
        showsSidebarToggle: Bool = false,
        isSidebarVisible: Bool = false,
        isThreadLoading: Bool = false,
        chatActions: CodexChatActionHandlers = CodexChatActionHandlers(),
        approvalOptions: [CodexApprovalSelection] = CodexApprovalSelection.defaultOptions,
        modelOptions: [CodexModelSelection] = CodexModelSelection.defaultOptions,
        slashCommands: [CodexSlashCommand] = CodexSlashCommand.observedCommands,
        mcpServers: [CodexMCPServerStatus] = [],
        isLoadingMCPServers: Bool = false,
        mcpErrorMessage: String? = nil,
        approvalSelection: Binding<CodexApprovalSelection> = .constant(.fullAccess),
        isPlanModeEnabled: Binding<Bool> = .constant(false),
        modelSelection: Binding<CodexModelSelection> = .constant(.appServerDefault),
        reasoningSelection: Binding<CodexReasoningSelection> = .constant(.medium),
        draft: Binding<String>,
        sideChatDraft: Binding<String> = .constant(""),
        isSending: Bool,
        isSideChatSending: Bool = false,
        canSend: Bool,
        canSendSideChatMessage: Bool = false,
        canUsePlanMode: Bool = true,
        isGoalPursuitEnabled: Bool = false,
        followUpHint: String? = nil,
        mentionResults: [FuzzyFileSearchResult] = [],
        onMentionQueryChanged: ((String?) -> Void)? = nil,
        onMentionSelected: ((FuzzyFileSearchResult) -> Void)? = nil,
        onSend: @escaping () -> Void,
        onInterrupt: @escaping () -> Void,
        onSendSideChatMessage: @escaping () -> Void = {},
        onInterruptSideChatMessage: @escaping () -> Void = {},
        onComposerAddMenuRoute: ((CodexComposerAddMenuRoute) -> Void)? = nil,
        onComposerChipClear: ((CodexComposerChipKind) -> Void)? = nil,
        onEnvironmentHandoffCompletion: (@MainActor @Sendable (CodexWorktreeHandoffCompletion) -> Void)? = nil,
        onCloseTranscriptMessage: ((UUID) -> Void)? = nil,
        onOpenMCPDetails: (() -> Void)? = nil,
        onRefreshMCPServers: (() -> Void)? = nil,
        onToggleSidebar: @escaping () -> Void = {},
        onDisconnect: @escaping () -> Void,
        onPromptSelected: ((String) -> Void)? = nil,
        onSlashCommandSelected: ((CodexSlashCommand) -> Void)? = nil
    ) {
        self.messages = messages
        self.lifecycleEvents = lifecycleEvents
        self.sideChat = sideChat
        self.subagents = subagents
        self.activities = activities
        self.connectionState = connectionState
        self.workspacePath = workspacePath
        self.chatTitle = chatTitle
        self.currentThreadID = currentThreadID
        self.rateLimitBannerMessage = rateLimitBannerMessage
        self.workspaceSummary = workspaceSummary
        self.gitReviewSession = gitReviewSession
        self.showsSidebarToggle = showsSidebarToggle
        self.isSidebarVisible = isSidebarVisible
        self.isThreadLoading = isThreadLoading
        self.chatActions = chatActions
        self.approvalOptions = approvalOptions
        self.modelOptions = modelOptions
        self.slashCommands = slashCommands
        self.mcpServers = mcpServers
        self.isLoadingMCPServers = isLoadingMCPServers
        self.mcpErrorMessage = mcpErrorMessage
        self._approvalSelection = approvalSelection
        self._isPlanModeEnabled = isPlanModeEnabled
        self._modelSelection = modelSelection
        self._reasoningSelection = reasoningSelection
        self._draft = draft
        self._sideChatDraft = sideChatDraft
        self.isSending = isSending
        self.isSideChatSending = isSideChatSending
        self.canSend = canSend
        self.canSendSideChatMessage = canSendSideChatMessage
        self.canUsePlanMode = canUsePlanMode
        self.isGoalPursuitEnabled = isGoalPursuitEnabled
        self.followUpHint = followUpHint
        self.mentionResults = mentionResults
        self.onMentionQueryChanged = onMentionQueryChanged
        self.onMentionSelected = onMentionSelected
        self.onSend = onSend
        self.onInterrupt = onInterrupt
        self.onSendSideChatMessage = onSendSideChatMessage
        self.onInterruptSideChatMessage = onInterruptSideChatMessage
        self.onComposerAddMenuRoute = onComposerAddMenuRoute
        self.onComposerChipClear = onComposerChipClear
        self.onEnvironmentHandoffCompletion = onEnvironmentHandoffCompletion
        self.onCloseTranscriptMessage = onCloseTranscriptMessage
        self.onOpenMCPDetails = onOpenMCPDetails
        self.onRefreshMCPServers = onRefreshMCPServers
        self.onToggleSidebar = onToggleSidebar
        self.onDisconnect = onDisconnect
        self.onPromptSelected = onPromptSelected
        self.onSlashCommandSelected = onSlashCommandSelected
    }

    public var body: some View {
        GeometryReader { proxy in
            let panelState = CodexWorkspaceResponsivePanelState(availableWidth: proxy.size.width)

            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    mainColumn(panelState: panelState)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if panelState.usesPersistentSidePanel, isAgentPanelOpen {
                        agentSidePanel(resizable: true)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }

                if panelState.usesOverlaySummaryPanel, isCompactSummaryPanelPresented {
                    compactOverlayBackdrop {
                        isCompactSummaryPanelPresented = false
                    }
                    .transition(.opacity)

                    floatingSummaryPanel
                        .padding(.top, 58)
                        .padding(.trailing, 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing)))
                }

                if panelState.usesOverlaySidePanel, isAgentPanelOpen {
                    compactOverlayBackdrop {
                        isAgentPanelOpen = false
                    }
                    .transition(.opacity)

                    agentSidePanel(resizable: false)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping), value: isAgentPanelOpen)
        .animation(.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping), value: isCompactSummaryPanelPresented)
        .animation(.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping), value: isSummaryPanelOpen)
        .background(theme.colors.canvas.opacity(0.001))
    }

    private func mainColumn(panelState: CodexWorkspaceResponsivePanelState) -> some View {
        return HStack(spacing: 0) {
            chatColumn()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if panelState.usesFloatingSummaryPanel, isSummaryPanelOpen, !isAgentPanelOpen {
                Divider()
                    .overlay(theme.colors.border)
                    .padding(.vertical, 12)

                floatingSummaryPanel
                    .frame(width: theme.spacing.summaryPanelWidth)
                    .padding(.top, 58)
                    .padding(.trailing, 16)
                    .padding(.leading, 4)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 540)
    }

    private func chatColumn() -> some View {
        ZStack(alignment: .topTrailing) {
            CodexTranscriptView(
                messages: messages,
                transcriptID: currentThreadID,
                lifecycleEvents: lifecycleEvents,
                activeTurn: activeTurnState,
                onCloseMessage: onCloseTranscriptMessage,
                onOpenMCPDetails: onOpenMCPDetails,
                onEditUserMessage: { draft = $0 },
                topContentMargin: 58,
                bottomContentMargin: 122
            ) {
                if isThreadLoading {
                    CodexThreadLoadingView()
                } else {
                    CodexEmptyTranscriptView { prompt in
                        if let onPromptSelected {
                            onPromptSelected(prompt)
                        } else {
                            draft = prompt
                        }
                    }
                }
            }

            VStack(spacing: 0) {
                CodexChatHeader(
                    title: chatTitle,
                    workspacePath: workspacePath,
                    showsSidebarToggle: showsSidebarToggle,
                    isSidebarVisible: isSidebarVisible,
                    isSummaryPanelOpen: isSummaryPanelOpen,
                    hasPanelTabs: true,
                    isPanelOpen: isAgentPanelOpen,
                    chatActions: workspaceChatActions,
                    onToggleSidebar: onToggleSidebar,
                    onToggleSummaryPanel: {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                            isSummaryPanelOpen.toggle()
                        }
                    },
                    onTogglePanel: toggleAgentPanel,
                    onDisconnect: onDisconnect
                )

                Spacer(minLength: 0)
                if let rateLimitBannerMessage {
                    CodexRateLimitBanner(message: rateLimitBannerMessage)
                        .frame(maxWidth: theme.spacing.composerMaxWidth + 32, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 6)
                }
                CodexComposerBar(
                    draft: $draft,
                    approvalSelection: $approvalSelection,
                    isPlanModeEnabled: $isPlanModeEnabled,
                    isGoalPursuitEnabled: isGoalPursuitEnabled,
                    approvalOptions: approvalOptions,
                    modelSelection: $modelSelection,
                    modelOptions: modelOptions,
                    reasoningSelection: $reasoningSelection,
                    slashCommands: slashCommands,
                    mcpServers: mcpServers,
                    isLoadingMCPServers: isLoadingMCPServers,
                    mcpErrorMessage: mcpErrorMessage,
                    isSending: isSending,
                    canSend: canSend,
                    canUsePlanMode: canUsePlanMode,
                    followUpHint: followUpHint,
                    mentionResults: mentionResults,
                    onMentionQueryChanged: onMentionQueryChanged,
                    onMentionSelected: onMentionSelected,
                    onSend: onSend,
                    onInterrupt: onInterrupt,
                    onSlashCommandSelected: onSlashCommandSelected,
                    onOpenMCPDetails: onOpenMCPDetails,
                    onRefreshMCPServers: onRefreshMCPServers,
                    onAddMenuRoute: onComposerAddMenuRoute,
                    onComposerChipClear: onComposerChipClear
                )
            }
        }
    }

    private var activeTurnState: CodexActiveTurnState? {
        guard isSending else { return nil }
        if let lastAssistant = messages.last(where: { $0.role == .assistant }), lastAssistant.isStreaming {
            return nil
        }
        let turnActivity = activities.first { $0.kind == .turn || $0.kind == .tool }
        return CodexActiveTurnState(
            activity: turnActivity,
            startedAt: activities.first { $0.kind == .turn }?.createdAt ?? turnActivity?.createdAt ?? Date()
        )
    }

    private var panelTabs: [CodexAgentPanelTab] {
        var tabs: [CodexAgentPanelTab] = []
        if let gitReviewSession { tabs.append(.review(gitReviewSession)) }
        if let sideChat { tabs.append(.sideChat(sideChat)) }
        tabs.append(contentsOf: subagents.map(CodexAgentPanelTab.subagent))
        return tabs
    }

    private var workspaceChatActions: CodexChatActionHandlers {
        var actions = chatActions
        if let openSideChat = chatActions.openSideChat {
            actions.openSideChat = {
                openSideChat()
                openPanelTab(CodexSideChatState.defaultID)
            }
        }
        return actions
    }

    private var floatingSummaryPanel: some View {
        CodexFloatingSummaryPanel(
            sideChat: sideChat,
            subagents: subagents,
            workspaceSummary: workspaceSummary,
            gitReviewSession: gitReviewSession,
            chatTitle: chatTitle,
            onEnvironmentHandoffCompletion: { completion in
                onEnvironmentHandoffCompletion?(completion)
            },
            onSelectTab: openPanelTab
        )
    }

    private func agentSidePanel(resizable: Bool) -> some View {
        CodexAgentSidePanel(
            tabs: panelTabs,
            selectedTabID: $selectedPanelTabID,
            width: resizable ? $agentPanelWidth : .constant(theme.spacing.sidePanelWidth),
            terminalSessions: terminalSessions,
            browserSessions: browserSessions,
            sideChatDraft: $sideChatDraft,
            isSideChatSending: isSideChatSending,
            canSendSideChatMessage: canSendSideChatMessage,
            onSendSideChatMessage: onSendSideChatMessage,
            onInterruptSideChatMessage: onInterruptSideChatMessage,
            onOpenTerminal: openTerminalTab,
            onOpenBrowser: openBrowserTab,
            onCloseTerminal: closeTerminalTab,
            onCloseBrowser: closeBrowserTab,
            onClose: { withAnimation(.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping)) { isAgentPanelOpen = false } }
        )
    }

    private func compactOverlayBackdrop(onDismiss: @escaping () -> Void) -> some View {
        theme.colors.canvas.opacity(0.42)
            .ignoresSafeArea()
            .onTapGesture(perform: onDismiss)
    }

    private func openPanelTab(_ id: String) {
        selectedPanelTabID = id
        isCompactSummaryPanelPresented = false
        withAnimation(.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping)) {
            isAgentPanelOpen = true
        }
    }

    private func toggleAgentPanel() {
        if selectedPanelTabID == nil {
            selectedPanelTabID = terminalSessions.first?.id ?? browserSessions.first?.id ?? panelTabs.first?.id
        }
        withAnimation(.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping)) {
            isAgentPanelOpen.toggle()
        }
    }

    private func toggleSummaryPanel(panelState: CodexWorkspaceResponsivePanelState) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            if panelState.usesFloatingSummaryPanel {
                isSummaryPanelOpen.toggle()
            } else {
                isCompactSummaryPanelPresented.toggle()
            }
        }
    }

    private func openTerminalTab() {
        let terminalNumber = nextTerminalNumber
        nextTerminalNumber += 1
        let title = terminalNumber == 1 ? "Terminal" : "Terminal \(terminalNumber)"
        let session = CodexTerminalSession(title: title, workingDirectory: workspacePath)
        terminalSessions.append(session)
        selectedPanelTabID = session.id
        withAnimation(.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping)) {
            isAgentPanelOpen = true
        }
    }

    private func closeTerminalTab(_ id: String) {
        terminalSessions.removeAll { $0.id == id }
        if selectedPanelTabID == id {
            selectedPanelTabID = terminalSessions.first?.id ?? browserSessions.first?.id ?? panelTabs.first?.id
        }
    }

    private func openBrowserTab() {
        let browserNumber = nextBrowserNumber
        nextBrowserNumber += 1
        let title = browserNumber == 1 ? "Browser" : "Browser \(browserNumber)"
        let session = CodexBrowserSession(title: title)
        browserSessions.append(session)
        selectedPanelTabID = session.id
        withAnimation(.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping)) {
            isAgentPanelOpen = true
        }
    }

    private func closeBrowserTab(_ id: String) {
        browserSessions.first { $0.id == id }?.close()
        browserSessions.removeAll { $0.id == id }
        if selectedPanelTabID == id {
            selectedPanelTabID = terminalSessions.first?.id ?? browserSessions.first?.id ?? panelTabs.first?.id
        }
    }
}

public struct CodexThreadLoadingView: View {
    @Environment(\.codexAgentTheme) private var theme

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer().frame(height: 40)
            HStack(spacing: 9) {
                CodexSpinner(size: .small)
                Text("Loading chat")
                    .font(theme.fonts.label)
                    .foregroundStyle(theme.colors.textSecondary)
            }
            ForEach(0..<4, id: \.self) { index in
                skeletonRow(short: index % 2 == 1)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading chat")
    }

    private func skeletonRow(short: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(theme.colors.surfaceElevated.opacity(0.55))
            .frame(width: short ? 180 : nil, height: 14)
            .frame(maxWidth: short ? nil : (theme.spacing.transcriptMaxWidth - 40), alignment: .leading)
    }
}

public struct CodexChatHeader: View {
    @Environment(\.codexAgentTheme) private var theme

    private let title: String
    private let workspacePath: String
    private let showsSidebarToggle: Bool
    private let isSidebarVisible: Bool
    private let isSummaryPanelOpen: Bool
    private let hasPanelTabs: Bool
    private let isPanelOpen: Bool
    private let chatActions: CodexChatActionHandlers
    private let onToggleSidebar: () -> Void
    private let onToggleSummaryPanel: () -> Void
    private let onTogglePanel: () -> Void
    private let onDisconnect: () -> Void

    public init(
        title: String = "Codex",
        workspacePath: String,
        showsSidebarToggle: Bool = false,
        isSidebarVisible: Bool = true,
        isSummaryPanelOpen: Bool = true,
        hasPanelTabs: Bool = false,
        isPanelOpen: Bool = false,
        chatActions: CodexChatActionHandlers = CodexChatActionHandlers(),
        onToggleSidebar: @escaping () -> Void = {},
        onToggleSummaryPanel: @escaping () -> Void = {},
        onTogglePanel: @escaping () -> Void = {},
        onDisconnect: @escaping () -> Void
    ) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Codex" : title
        self.workspacePath = workspacePath
        self.showsSidebarToggle = showsSidebarToggle
        self.isSidebarVisible = isSidebarVisible
        self.isSummaryPanelOpen = isSummaryPanelOpen
        self.hasPanelTabs = hasPanelTabs
        self.isPanelOpen = isPanelOpen
        self.chatActions = chatActions
        self.onToggleSidebar = onToggleSidebar
        self.onToggleSummaryPanel = onToggleSummaryPanel
        self.onTogglePanel = onTogglePanel
        self.onDisconnect = onDisconnect
    }

    public var body: some View {
        HStack(spacing: 7) {
            if showsSidebarToggle {
                ToolbarIconButton(
                    systemImage: "sidebar.left",
                    isActive: isSidebarVisible,
                    help: "Toggle sidebar",
                    action: onToggleSidebar
                )
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(theme.fonts.chat)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(theme.fonts.caption)
                    Text(codexShortPath(workspacePath))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textTertiary)
            }
            .frame(maxWidth: 360, alignment: .leading)

            Spacer(minLength: 12)

            ChatActionsMenu(actions: chatActions, onDisconnect: onDisconnect)

            ToolbarIconButton(
                systemImage: "list.bullet.rectangle",
                isActive: isSummaryPanelOpen,
                help: "Toggle pinned summary",
                action: onToggleSummaryPanel
            )

            ToolbarIconButton(
                systemImage: "sidebar.right",
                isActive: isPanelOpen,
                isEnabled: hasPanelTabs,
                help: "Toggle side panel",
                action: onTogglePanel
            )

            ToolbarIconButton(systemImage: "xmark", help: "Disconnect", action: onDisconnect)
        }
        .frame(height: theme.spacing.toolbarHeight)
        .padding(.horizontal, 10)
        .codexGlass(Rectangle(), tint: theme.colors.surface.opacity(0.14))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.colors.border.opacity(0.24))
                .frame(height: 1)
        }
    }
}

private struct ToolbarIconButton: View {
    @Environment(\.codexAgentTheme) private var theme

    let systemImage: String
    var isActive = false
    var isEnabled = true
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(theme.fonts.label)
                .foregroundStyle(isEnabled ? theme.colors.textSecondary : theme.colors.textTertiary.opacity(theme.effects.textFaintOpacity))
                .frame(width: theme.spacing.iconLarge, height: theme.spacing.iconLarge)
                .background(
                    isActive ? theme.colors.surfaceElevated.opacity(theme.effects.textDimOpacity) : .clear,
                    in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
    }
}

private struct ChatActionsMenu: View {
    @Environment(\.codexAgentTheme) private var theme

    let actions: CodexChatActionHandlers
    let onDisconnect: () -> Void

    var body: some View {
        Menu {
            ForEach(actions.menuItems.prefix(3), id: \.id) { item in
                actionButton(item)
            }
            Divider()
            ForEach(actions.menuItems.dropFirst(3).prefix(3), id: \.id) { item in
                actionButton(item)
            }
            Divider()
            ForEach(actions.menuItems.dropFirst(6), id: \.id) { item in
                actionButton(item)
            }
            Divider()
            Button("Disconnect", action: onDisconnect)
        } label: {
            Image(systemName: "ellipsis")
                .font(theme.fonts.chat)
                .foregroundStyle(theme.colors.textSecondary)
                .frame(width: theme.spacing.iconLarge, height: theme.spacing.iconLarge)
                .contentShape(RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
        }
        .fixedSize()
        .help("Chat actions")
    }

    private func actionButton(_ item: CodexChatActionMenuItem) -> some View {
        Button(item.displayTitle) {
            actions.perform(item.id)
        }
        .disabled(!item.isEnabled)
    }
}

private func codexShortPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
    return path
}
