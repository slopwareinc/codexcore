import SwiftUI
import CodexCore

private struct CodexComposerOverlayHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

public struct CodexWorkspaceResponsivePanelState: Equatable, Sendable {
    public var availableWidth: CGFloat

    public init(availableWidth: CGFloat) {
        self.availableWidth = max(0, availableWidth)
    }

    public var supportsDockedOverviewWithoutSidePanel: Bool {
        availableWidth >= 1_300
    }

    public var supportsDockedOverviewWithSidePanel: Bool {
        availableWidth >= 1_740
    }

    public func supportsDockedOverview(isSidePanelOpen: Bool) -> Bool {
        isSidePanelOpen ? supportsDockedOverviewWithSidePanel : supportsDockedOverviewWithoutSidePanel
    }

    public var usesPersistentSidePanel: Bool {
        availableWidth >= 980
    }

    public var usesFloatingSummaryPanel: Bool {
        supportsDockedOverviewWithoutSidePanel
    }

    public var usesOverlaySummaryPanel: Bool {
        !supportsDockedOverviewWithoutSidePanel
    }

    public var usesOverlaySidePanel: Bool {
        !usesPersistentSidePanel
    }
}

/// A complete reusable Codex chat workspace: transcript, header, composer, and agent panels.
public struct CodexChatWorkspaceView: View {
    @Environment(\.codexAgentTheme) private var theme

    private let presentationStore: CodexPresentationStore
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
    private let leadingTitlebarInset: CGFloat
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
    @Binding private var referencedFiles: [CodexReferencedFile]
    @Binding private var sideChatDraft: String
    private let isSending: Bool
    private let isSideChatSending: Bool
    private let canSend: Bool
    private let canSendSideChatMessage: Bool
    private let canUsePlanMode: Bool
    private let isGoalPursuitEnabled: Bool
    private let followUpHint: String?
    private let queuedFollowUps: [CodexComposerSubmission]
    private let mentionResults: [FuzzyFileSearchResult]
    private let onMentionQueryChanged: ((String?) -> Void)?
    private let onMentionSelected: ((FuzzyFileSearchResult) -> Void)?
    private let onSend: () -> Void
    private let onInterrupt: () -> Void
    private let onStartVoiceChat: (() -> Void)?
    private let onSteerQueuedFollowUp: (String) -> Void
    private let onRemoveQueuedFollowUp: (String) -> Void
    private let onEditQueuedFollowUp: (String) -> Void
    private let onSendSideChatMessage: () -> Void
    private let onInterruptSideChatMessage: () -> Void
    private let onComposerAddMenuRoute: ((CodexComposerAddMenuRoute) -> Void)?
    private let onComposerChipClear: ((CodexComposerChipKind) -> Void)?
    private let onFilesDropped: (@MainActor @Sendable ([URL]) -> Void)?
    private let onEnvironmentHandoffCompletion: (@MainActor @Sendable (CodexWorktreeHandoffCompletion) -> Void)?
    private let onCloseTranscriptMessage: ((UUID) -> Void)?
    private let onOpenMCPDetails: (() -> Void)?
    private let onRefreshMCPServers: (() -> Void)?
    private let onToggleSidebar: () -> Void
    private let onDisconnect: () -> Void
    private let onPromptSelected: ((String) -> Void)?
    private let onSlashCommandSelected: ((CodexSlashCommand) -> Void)?
    private let approvalPrompts: [CodexApprovalPrompt]
    private let onResolveApproval: (CodexServerRequestKey, Bool) -> Void
    private let showsComposer: Bool
    @ObservedObject private var panel: CodexWorkspacePanelState
    private let mountedPanels: [CodexWorkspacePanelState]
    @State private var isSummaryPanelOpen = true
    @State private var isCompactSummaryPanelPresented = false
    @State private var composerOverlayHeight: CGFloat = 170
    @State private var hiddenSubagentTabIDs: Set<String> = []

    public init(
        presentationStore: CodexPresentationStore,
        lifecycleEvents: [CodexAgentLifecycleEvent] = [],
        sideChat: CodexSideChatState? = nil,
        subagents: [CodexSubagentState] = [],
        activities: [CodexActivity],
        connectionState: CodexConnectionState,
        workspacePath: String,
        chatTitle: String = "Codex",
        currentThreadID: String? = nil,
        panel: CodexWorkspacePanelState = CodexWorkspacePanelState(),
        mountedPanels: [CodexWorkspacePanelState] = [],
        rateLimitBannerMessage: String? = nil,
        workspaceSummary: CodexWorkspaceSummaryContext? = nil,
        gitReviewSession: CodexGitReviewSession? = nil,
        showsSidebarToggle: Bool = false,
        isSidebarVisible: Bool = false,
        leadingTitlebarInset: CGFloat = 0,
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
        referencedFiles: Binding<[CodexReferencedFile]> = .constant([]),
        sideChatDraft: Binding<String> = .constant(""),
        isSending: Bool,
        isSideChatSending: Bool = false,
        canSend: Bool,
        canSendSideChatMessage: Bool = false,
        canUsePlanMode: Bool = true,
        isGoalPursuitEnabled: Bool = false,
        followUpHint: String? = nil,
        queuedFollowUps: [CodexComposerSubmission] = [],
        mentionResults: [FuzzyFileSearchResult] = [],
        onMentionQueryChanged: ((String?) -> Void)? = nil,
        onMentionSelected: ((FuzzyFileSearchResult) -> Void)? = nil,
        onSend: @escaping () -> Void,
        onInterrupt: @escaping () -> Void,
        onStartVoiceChat: (() -> Void)? = nil,
        onSteerQueuedFollowUp: @escaping (String) -> Void = { _ in },
        onRemoveQueuedFollowUp: @escaping (String) -> Void = { _ in },
        onEditQueuedFollowUp: @escaping (String) -> Void = { _ in },
        onSendSideChatMessage: @escaping () -> Void = {},
        onInterruptSideChatMessage: @escaping () -> Void = {},
        onComposerAddMenuRoute: ((CodexComposerAddMenuRoute) -> Void)? = nil,
        onComposerChipClear: ((CodexComposerChipKind) -> Void)? = nil,
        onFilesDropped: (@MainActor @Sendable ([URL]) -> Void)? = nil,
        onEnvironmentHandoffCompletion: (@MainActor @Sendable (CodexWorktreeHandoffCompletion) -> Void)? = nil,
        onCloseTranscriptMessage: ((UUID) -> Void)? = nil,
        onOpenMCPDetails: (() -> Void)? = nil,
        onRefreshMCPServers: (() -> Void)? = nil,
        onToggleSidebar: @escaping () -> Void = {},
        onDisconnect: @escaping () -> Void,
        onPromptSelected: ((String) -> Void)? = nil,
        onSlashCommandSelected: ((CodexSlashCommand) -> Void)? = nil,
        approvalPrompts: [CodexApprovalPrompt] = [],
        onResolveApproval: @escaping (CodexServerRequestKey, Bool) -> Void = { _, _ in },
        showsComposer: Bool = true
    ) {
        self.presentationStore = presentationStore
        self.lifecycleEvents = lifecycleEvents
        self.sideChat = sideChat
        self.subagents = subagents
        self.activities = activities
        self.connectionState = connectionState
        self.workspacePath = workspacePath
        self.chatTitle = chatTitle
        self.currentThreadID = currentThreadID
        self._panel = ObservedObject(wrappedValue: panel)
        self.mountedPanels = mountedPanels
        self.rateLimitBannerMessage = rateLimitBannerMessage
        self.workspaceSummary = workspaceSummary
        self.gitReviewSession = gitReviewSession
        self.showsSidebarToggle = showsSidebarToggle
        self.isSidebarVisible = isSidebarVisible
        self.leadingTitlebarInset = max(0, leadingTitlebarInset)
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
        self._referencedFiles = referencedFiles
        self._sideChatDraft = sideChatDraft
        self.isSending = isSending
        self.isSideChatSending = isSideChatSending
        self.canSend = canSend
        self.canSendSideChatMessage = canSendSideChatMessage
        self.canUsePlanMode = canUsePlanMode
        self.isGoalPursuitEnabled = isGoalPursuitEnabled
        self.followUpHint = followUpHint
        self.queuedFollowUps = queuedFollowUps
        self.mentionResults = mentionResults
        self.onMentionQueryChanged = onMentionQueryChanged
        self.onMentionSelected = onMentionSelected
        self.onSend = onSend
        self.onInterrupt = onInterrupt
        self.onStartVoiceChat = onStartVoiceChat
        self.onSteerQueuedFollowUp = onSteerQueuedFollowUp
        self.onRemoveQueuedFollowUp = onRemoveQueuedFollowUp
        self.onEditQueuedFollowUp = onEditQueuedFollowUp
        self.onSendSideChatMessage = onSendSideChatMessage
        self.onInterruptSideChatMessage = onInterruptSideChatMessage
        self.onComposerAddMenuRoute = onComposerAddMenuRoute
        self.onComposerChipClear = onComposerChipClear
        self.onFilesDropped = onFilesDropped
        self.onEnvironmentHandoffCompletion = onEnvironmentHandoffCompletion
        self.onCloseTranscriptMessage = onCloseTranscriptMessage
        self.onOpenMCPDetails = onOpenMCPDetails
        self.onRefreshMCPServers = onRefreshMCPServers
        self.onToggleSidebar = onToggleSidebar
        self.onDisconnect = onDisconnect
        self.onPromptSelected = onPromptSelected
        self.onSlashCommandSelected = onSlashCommandSelected
        self.approvalPrompts = approvalPrompts
        self.onResolveApproval = onResolveApproval
        self.showsComposer = showsComposer
    }

    public var body: some View {
        GeometryReader { proxy in
            let panelState = CodexWorkspaceResponsivePanelState(availableWidth: proxy.size.width)
            let isDockedOverviewVisible = isSummaryPanelOpen && panelState.supportsDockedOverview(isSidePanelOpen: panel.isAgentPanelOpen)
            let isFloatingOverviewVisible = isCompactSummaryPanelPresented && !isDockedOverviewVisible
            // Float the overview over the main chat column, not the side panel:
            // when the persistent side panel is open, inset past its width.
            let floatingOverviewTrailingInset = 16 + (panelState.usesPersistentSidePanel && panel.isAgentPanelOpen ? panel.panelWidth : 0)

            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    mainColumn(
                        panelState: panelState,
                        isDockedOverviewVisible: isDockedOverviewVisible,
                        isOverviewControlActive: isDockedOverviewVisible || isFloatingOverviewVisible
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if panelState.usesPersistentSidePanel, panel.isAgentPanelOpen {
                        agentSidePanel(resizable: true)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }

                if isFloatingOverviewVisible {
                    compactOverlayBackdrop {
                        isCompactSummaryPanelPresented = false
                    }
                    .transition(.opacity)

                    floatingSummaryPanel
                        .padding(.top, 58)
                        .padding(.trailing, floatingOverviewTrailingInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing)))
                }

                if panelState.usesOverlaySidePanel, panel.isAgentPanelOpen {
                    compactOverlayBackdrop {
                        panel.isAgentPanelOpen = false
                    }
                    .transition(.opacity)

                    agentSidePanel(resizable: true)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping), value: panel.isAgentPanelOpen)
        .animation(.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping), value: isCompactSummaryPanelPresented)
        .animation(.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping), value: isSummaryPanelOpen)
        .background(theme.colors.canvas.opacity(0.001))
    }

    private func mainColumn(
        panelState: CodexWorkspaceResponsivePanelState,
        isDockedOverviewVisible: Bool,
        isOverviewControlActive: Bool
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            chatColumn(
                panelState: panelState,
                isOverviewControlActive: isOverviewControlActive,
                isDockedOverviewVisible: isDockedOverviewVisible
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 540)
    }

    private func chatColumn(
        panelState: CodexWorkspaceResponsivePanelState,
        isOverviewControlActive: Bool,
        isDockedOverviewVisible: Bool
    ) -> some View {
        let contentShift = isDockedOverviewVisible ? dockedOverviewContentShift : 0

        return ZStack(alignment: .topTrailing) {
            CodexTranscriptViewV2(
                presentationStore: presentationStore,
                contentHorizontalOffset: -contentShift,
                bottomContentInset: composerOverlayHeight + 20,
                onOpenSubagent: openPanelTab,
                onEditUserMessage: { rawText in
                    if let decoded = CodexFileReferencePromptCodec.decode(rawText) {
                        draft = decoded.request
                        referencedFiles = decoded.files
                    } else {
                        draft = rawText
                        referencedFiles = []
                    }
                },
                onForkChat: chatActions.forkChat,
                agentDisplayNameByThreadID: Dictionary(
                    uniqueKeysWithValues: subagents.map { ($0.id, $0.name) }
                ),
                pendingApprovals: approvalPrompts,
                onResolveApproval: onResolveApproval
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
            .overlay(alignment: .topTrailing) {
                if isDockedOverviewVisible {
                    floatingSummaryPanel
                        .frame(width: theme.spacing.summaryPanelWidth)
                        .padding(.top, 58)
                        .padding(.trailing, 28)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing)))
                }
            }

            VStack(spacing: 0) {
                CodexChatHeader(
                    title: chatTitle,
                    workspacePath: workspacePath,
                    showsSidebarToggle: showsSidebarToggle,
                    isSidebarVisible: isSidebarVisible,
                    leadingTitlebarInset: leadingTitlebarInset,
                    isSummaryPanelOpen: isOverviewControlActive,
                    hasPanelTabs: true,
                    isPanelOpen: panel.isAgentPanelOpen,
                    chatActions: workspaceChatActions,
                    onToggleSidebar: onToggleSidebar,
                    onToggleSummaryPanel: {
                        toggleSummaryPanel(panelState: panelState)
                    },
                    onTogglePanel: toggleAgentPanel,
                    onDisconnect: onDisconnect
                )

                Spacer(minLength: 0)
                if showsComposer {
                    VStack(spacing: 0) {
                    if let rateLimitBannerMessage {
                        CodexRateLimitBanner(message: rateLimitBannerMessage)
                            .frame(maxWidth: theme.spacing.composerMaxWidth + 32, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 6)
                            .offset(x: -contentShift)
                    }
                    if !queuedFollowUps.isEmpty {
                        CodexQueuedFollowUpStack(
                            submissions: queuedFollowUps,
                            canSteer: isSending,
                            onSteer: onSteerQueuedFollowUp,
                            onRemove: onRemoveQueuedFollowUp,
                            onEdit: onEditQueuedFollowUp
                        )
                        .frame(maxWidth: theme.spacing.composerMaxWidth + 32, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                        .offset(x: -contentShift)
                    }
                    CodexComposerBar(
                        draft: $draft,
                        referencedFiles: $referencedFiles,
                        approvalSelection: $approvalSelection,
                        isPlanModeEnabled: $isPlanModeEnabled,
                        isGoalPursuitEnabled: isGoalPursuitEnabled,
                        approvalOptions: approvalOptions,
                        modelSelection: $modelSelection,
                        modelOptions: modelOptions,
                        modelPickerStyle: .grid,
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
                        onStartVoiceChat: onStartVoiceChat,
                        onSlashCommandSelected: onSlashCommandSelected,
                        onOpenMCPDetails: onOpenMCPDetails,
                        onRefreshMCPServers: onRefreshMCPServers,
                        onAddMenuRoute: onComposerAddMenuRoute,
                        onComposerChipClear: onComposerChipClear,
                        onFilesDropped: onFilesDropped
                    )
                    .frame(maxWidth: theme.spacing.composerMaxWidth + 32, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 22)
                    .offset(x: -contentShift)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                    }
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: CodexComposerOverlayHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    }
                }
            }
        }
        .onPreferenceChange(CodexComposerOverlayHeightKey.self) { height in
            guard height > 0 else { return }
            composerOverlayHeight = height
        }
    }

    private var dockedOverviewContentShift: CGFloat {
        min(theme.spacing.summaryPanelWidth * 0.38, 120)
    }

    private var panelTabs: [CodexAgentPanelTab] {
        var tabs: [CodexAgentPanelTab] = []
        if let gitReviewSession { tabs.append(.review(gitReviewSession)) }
        if let sideChat { tabs.append(.sideChat(sideChat)) }
        tabs.append(contentsOf: subagents.map(CodexAgentPanelTab.subagent).filter { !hiddenSubagentTabIDs.contains($0.id) })
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

    // Union of tool sessions across all mounted recent chats, kept in one deck so
    // switching chats is a visibility toggle instead of remounting surfaces. The
    // active `panel` is appended last (and always observed) so its sessions stay
    // current; ids dedupe repeats.
    private var mountedTerminalSessions: [CodexTerminalSession] {
        var seen = Set<String>()
        return (mountedPanels + [panel]).flatMap(\.terminalSessions).filter { seen.insert($0.id).inserted }
    }

    private var mountedBrowserSessions: [CodexBrowserSession] {
        var seen = Set<String>()
        return (mountedPanels + [panel]).flatMap(\.browserSessions).filter { seen.insert($0.id).inserted }
    }

    private var mountedFilesSessions: [CodexFilesSession] {
        var seen = Set<String>()
        return (mountedPanels + [panel]).compactMap(\.filesSession).filter { seen.insert($0.id).inserted }
    }

    private var mountedFilePreviewSessions: [CodexFilePreviewSession] {
        var seen = Set<String>()
        return (mountedPanels + [panel]).flatMap(\.filePreviewSessions).filter { seen.insert($0.id).inserted }
    }

    private func agentSidePanel(resizable: Bool) -> some View {
        CodexAgentSidePanel(
            tabs: panelTabs,
            selectedTabID: $panel.selectedTabID,
            width: resizable ? $panel.panelWidth : .constant(theme.spacing.sidePanelWidth),
            terminalSessions: panel.terminalSessions,
            browserSessions: panel.browserSessions,
            filesSessions: panel.filesSession.map { [$0] } ?? [],
            filePreviewSessions: panel.filePreviewSessions,
            mountedTerminalSessions: mountedTerminalSessions,
            mountedBrowserSessions: mountedBrowserSessions,
            mountedFilesSessions: mountedFilesSessions,
            mountedFilePreviewSessions: mountedFilePreviewSessions,
            modelOptions: modelOptions,
            sideChatDraft: $sideChatDraft,
            isSideChatSending: isSideChatSending,
            canSendSideChatMessage: canSendSideChatMessage,
            onSendSideChatMessage: onSendSideChatMessage,
            onInterruptSideChatMessage: onInterruptSideChatMessage,
            onOpenTerminal: openTerminalTab,
            onOpenBrowser: openBrowserTab,
            onOpenFiles: openFilesTab,
            onOpenFilePreview: openFilePreviewTab,
            onCloseTerminal: closeTerminalTab,
            onCloseBrowser: closeBrowserTab,
            onCloseFiles: closeFilesTab,
            onCloseFilePreview: closeFilePreviewTab,
            onCloseSubagent: closeSubagentTab,
            onClose: { withAnimation(.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping)) { panel.isAgentPanelOpen = false } }
        )
    }

    private func compactOverlayBackdrop(onDismiss: @escaping () -> Void) -> some View {
        theme.colors.canvas.opacity(0.42)
            .ignoresSafeArea()
            .onTapGesture(perform: onDismiss)
    }

    private func openPanelTab(_ id: String) {
        hiddenSubagentTabIDs.remove(id)
        panel.selectedTabID = id
        isCompactSummaryPanelPresented = false
        withAnimation(.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping)) {
            panel.isAgentPanelOpen = true
        }
    }

    private func closeSubagentTab(_ id: String) {
        hiddenSubagentTabIDs.insert(id)
        panel.selectedTabID = panelTabs.first?.id
    }

    private func toggleAgentPanel() {
        if panel.selectedTabID == nil {
            panel.selectedTabID = panel.terminalSessions.first?.id
                ?? panel.browserSessions.first?.id
                ?? panel.filesSession?.id
                ?? panelTabs.first?.id
        }
        withAnimation(.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping)) {
            panel.isAgentPanelOpen.toggle()
        }
    }

    private func toggleSummaryPanel(panelState: CodexWorkspaceResponsivePanelState) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            if panelState.supportsDockedOverview(isSidePanelOpen: panel.isAgentPanelOpen) {
                isCompactSummaryPanelPresented = false
                isSummaryPanelOpen.toggle()
            } else {
                isCompactSummaryPanelPresented.toggle()
            }
        }
    }

    private func openTerminalTab() {
        panel.openTerminal(workspacePath: workspacePath)
        withAnimation(.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping)) {
            panel.isAgentPanelOpen = true
        }
    }

    private func closeTerminalTab(_ id: String) {
        panel.closeTerminal(id: id, fallbackTabIDs: panelTabs.map(\.id))
    }

    private func openBrowserTab() {
        panel.openBrowser()
        withAnimation(.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping)) {
            panel.isAgentPanelOpen = true
        }
    }

    private func closeBrowserTab(_ id: String) {
        panel.closeBrowser(id: id, fallbackTabIDs: panelTabs.map(\.id))
    }

    private func openFilesTab() {
        panel.openFiles(workspacePath: workspacePath)
        withAnimation(.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping)) {
            panel.isAgentPanelOpen = true
        }
    }

    private func closeFilesTab(_ id: String) {
        panel.closeFiles(id: id, fallbackTabIDs: panelTabs.map(\.id))
    }

    private func openFilePreviewTab(_ fileURL: URL) {
        panel.openFilePreview(fileURL: fileURL)
        withAnimation(.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping)) {
            panel.isAgentPanelOpen = true
        }
    }

    private func closeFilePreviewTab(_ id: String) {
        panel.closeFilePreview(id: id, fallbackTabIDs: panelTabs.map(\.id))
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
    private let leadingTitlebarInset: CGFloat
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
        leadingTitlebarInset: CGFloat = 0,
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
        self.leadingTitlebarInset = max(0, leadingTitlebarInset)
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
        ZStack(alignment: .top) {
            // Fades the transcript out as it scrolls beneath the controls so
            // text stays legible under the bubbles. Purely visual — hit testing
            // is off so content below the control row stays interactive.
            scrim
                .allowsHitTesting(false)

            controlsRow
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var scrim: some View {
        LinearGradient(
            colors: [
                theme.colors.canvas,
                theme.colors.canvas.opacity(0.82),
                theme.colors.canvas.opacity(0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: theme.spacing.toolbarHeight + 46)
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            if leadingTitlebarInset > 0 {
                Color.clear
                    .frame(width: leadingTitlebarInset)
            }

            if showsSidebarToggle {
                HeaderBubble {
                    ToolbarIconButton(
                        systemImage: "sidebar.leading",
                        isActive: isSidebarVisible,
                        help: "Toggle sidebar",
                        action: onToggleSidebar
                    )
                }
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

            HeaderBubble {
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
            }

            HeaderBubble {
                ToolbarIconButton(systemImage: "xmark", help: "Disconnect", action: onDisconnect)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: theme.spacing.toolbarHeight)
        .padding(.top, 8)
        // Window-drag region (isMovableByWindowBackground is off). Buttons and
        // menus keep their own hit priority, so only empty header area moves
        // the window. Scoped to the control row so the scrim tail below stays
        // pass-through to the transcript.
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
    }
}

/// A floating glass capsule that groups one or more header controls, à la the
/// macOS Notes/Reminders toolbar bubbles.
private struct HeaderBubble<Content: View>: View {
    @Environment(\.codexAgentTheme) private var theme
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 2) {
            content
        }
        .padding(.horizontal, 4)
        .frame(height: 34)
        .codexGlass(Capsule(), tint: theme.colors.surface.opacity(0.42))
        .overlay(Capsule().stroke(theme.colors.border.opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
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
                .foregroundStyle(foreground)
                .frame(width: theme.spacing.iconLarge, height: theme.spacing.iconLarge)
                // Selection is a concentric accent-tinted fill matching the
                // round button (Liquid Glass selection), not a squircle chip.
                .background(
                    isActive ? theme.colors.accent.opacity(0.22) : .clear,
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
    }

    private var foreground: Color {
        if !isEnabled {
            return theme.colors.textTertiary.opacity(theme.effects.textFaintOpacity)
        }
        // Active glyph brightens to the accent; inactive stays secondary.
        return isActive ? theme.colors.accent : theme.colors.textSecondary
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
        // Strip the default macOS pop-up bezel + disclosure arrow so the glyph
        // sits cleanly on the glass bubble like the sibling icon buttons,
        // instead of stacking its own gray chrome (the "hybrid" look).
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
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
    CodexPathFormatter.abbreviatingHome(path)
}
