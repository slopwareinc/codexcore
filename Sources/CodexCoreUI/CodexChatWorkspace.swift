import AppKit
import SwiftUI
import CodexCore

private struct CodexComposerOverlayHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum CodexComposerOverlayHeightReconciler {
    static func next(current: CGFloat, proposed: CGFloat) -> CGFloat? {
        guard proposed > 0, abs(current - proposed) > 0.5 else { return nil }
        return proposed
    }
}

public struct CodexWorkspaceResponsivePanelState: Equatable, Sendable {
    /// Preserves the transcript's 736-point reading measure plus its standard
    /// horizontal gutters while a tool panel is docked beside it.
    private static let minimumReadableChatWidth: CGFloat = 792

    public var availableWidth: CGFloat
    private var sidePanelWidth: CGFloat

    public init(availableWidth: CGFloat) {
        self.init(availableWidth: availableWidth, sidePanelWidth: 400)
    }

    init(
        availableWidth: CGFloat,
        sidePanelWidth: CGFloat
    ) {
        self.availableWidth = max(0, availableWidth)
        self.sidePanelWidth = min(max(sidePanelWidth, 300), 680)
    }

    public var supportsDockedOverviewWithoutSidePanel: Bool {
        availableWidth >= 1_300
    }

    public var supportsDockedOverviewWithSidePanel: Bool {
        availableWidth >= 1_300 + max(440, sidePanelWidth)
    }

    public func supportsDockedOverview(isSidePanelOpen: Bool) -> Bool {
        isSidePanelOpen ? supportsDockedOverviewWithSidePanel : supportsDockedOverviewWithoutSidePanel
    }

    public var usesPersistentSidePanel: Bool {
        availableWidth >= Self.minimumReadableChatWidth + sidePanelWidth
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

    var showsCloseButtonInsideSidePanel: Bool {
        usesOverlaySidePanel
    }
}

/// Stable, first-seen tool-session unions for the mounted chat panels.
///
/// The workspace keeps each legacy tool category in its own deck, so each
/// category needs an independent identity set. Collecting the legacy
/// categories together avoids rebuilding the mounted-panel array and
/// traversing every panel three times during one side-panel composition.
@MainActor
struct CodexMountedWorkspaceToolSessions {
    let browser: [CodexBrowserSession]

    init(panels: [CodexWorkspacePanelState]) {
        var browserIDs = Set<String>()
        var browser: [CodexBrowserSession] = []

        for panel in panels {
            for session in panel.browserSessions where browserIDs.insert(session.id).inserted {
                browser.append(session)
            }
        }

        self.browser = browser
    }
}

/// A complete reusable Codex chat workspace: transcript, header, composer, and agent panels.
public struct CodexChatWorkspaceView: View {
    @Environment(\.codexAgentTheme) private var theme

    private let presentationStore: CodexPresentationStore
    private let sideChat: CodexSideChatState?
    private let subagents: [CodexSubagentState]
    private let subagentCoordinator: CodexSubagentPresentationCoordinator?
    private let workspacePath: String
    private let visualizationRoots: [URL]
    private let chatTitle: String
    private let currentThreadID: String?
    private let rateLimitBannerMessage: String?
    private let workspaceSummary: CodexWorkspaceSummaryContext?
    private let threadResourceInventory: CodexThreadResourceInventory?
    private let onOpenResource: ((CodexWorkspaceTabRequest) -> Void)?
    private let gitReviewSession: CodexGitReviewSession?
    private let backgroundTerminalActions: CodexBackgroundTerminalActions?
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
    @Binding private var isModelMenuPresented: Bool
    @Binding private var focusComposerRequest: Bool
    @Binding private var serviceTierSelection: CodexServiceTierSelection
    @Binding private var reasoningSelection: CodexReasoningSelection
    @Binding private var draft: String
    @Binding private var referencedFiles: [CodexReferencedFile]
    @Binding private var responseAnnotations: [CodexResponseTextAnnotation]
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
    private let dictationState: CodexComposerDictationState
    private let dictationActions: CodexComposerDictationActions?
    private let onStartVoiceChat: (() -> Void)?
    private let voiceChatLabel: String
    private let composerFocusRequest: Int
    private let onSteerQueuedFollowUp: (String) -> Void
    private let onRemoveQueuedFollowUp: (String) -> Void
    private let onEditQueuedFollowUp: (String) -> Void
    private let onSendSideChatMessage: () -> Void
    private let onInterruptSideChatMessage: () -> Void
    private let onComposerAddMenuRoute: ((CodexComposerAddMenuRoute) -> Void)?
    private let onComposerChipClear: ((CodexComposerChipKind) -> Void)?
    private let onFilesDropped: (@MainActor @Sendable ([URL]) -> Void)?
    private let onEnvironmentHandoffCompletion: (@MainActor @Sendable (CodexWorktreeHandoffCompletion) -> Void)?
    private let onOpenThread: (CodexThreadReferenceV2) -> Void
    private let onStartReview: (CodexReviewTarget) -> Void
    private let onOpenMCPDetails: (() -> Void)?
    private let onRefreshMCPServers: (() -> Void)?
    private let onToggleSidebar: () -> Void
    private let onDisconnect: () -> Void
    private let onPromptSelected: ((String) -> Void)?
    private let onSlashCommandSelected: ((CodexSlashCommand) -> Void)?
    private let approvalPrompts: [CodexApprovalPrompt]
    private let onResolveApproval: (CodexServerRequestKey, Bool) -> Void
    private let showsComposer: Bool
    private let bottomAccessory: AnyView?
    private let supplementalTranscriptTurns: [CodexTurnV2]
    private let supplementalTranscriptPresentedAtByTurnID: [String: Date]
    @ObservedObject private var panel: CodexWorkspacePanelState
    @ObservedObject private var workspaceTabs: CodexWorkspaceTabs
    private let mountedPanels: [CodexWorkspacePanelState]
    @State private var isSummaryPanelOpen = true
    @State private var isCompactSummaryPanelPresented = false
    @State private var composerOverlayHeight: CGFloat = 170
    @StateObject private var visualizationFrames = CodexVisualizationFrameStore()

    /// Creates a workspace and routes the Subagents surface through the
    /// canonical presentation coordinator when one is supplied.
    public init(
        presentationStore: CodexPresentationStore,
        sideChat: CodexSideChatState? = nil,
        subagents: [CodexSubagentState] = [],
        subagentCoordinator: CodexSubagentPresentationCoordinator? = nil,
        workspacePath: String,
        visualizationRoots: [URL] = [],
        chatTitle: String = "Codex",
        currentThreadID: String? = nil,
        panel: CodexWorkspacePanelState = CodexWorkspacePanelState(),
        mountedPanels: [CodexWorkspacePanelState] = [],
        rateLimitBannerMessage: String? = nil,
        workspaceSummary: CodexWorkspaceSummaryContext? = nil,
        threadResourceInventory: CodexThreadResourceInventory? = nil,
        onOpenResource: ((CodexWorkspaceTabRequest) -> Void)? = nil,
        gitReviewSession: CodexGitReviewSession? = nil,
        backgroundTerminalActions: CodexBackgroundTerminalActions? = nil,
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
        approvalSelection: Binding<CodexApprovalSelection> = .constant(.askForApproval),
        isPlanModeEnabled: Binding<Bool> = .constant(false),
        modelSelection: Binding<CodexModelSelection> = .constant(.appServerDefault),
        isModelMenuPresented: Binding<Bool> = .constant(false),
        focusComposerRequest: Binding<Bool> = .constant(false),
        serviceTierSelection: Binding<CodexServiceTierSelection> = .constant(.standard),
        reasoningSelection: Binding<CodexReasoningSelection> = .constant(.medium),
        draft: Binding<String>,
        referencedFiles: Binding<[CodexReferencedFile]> = .constant([]),
        responseAnnotations: Binding<[CodexResponseTextAnnotation]> = .constant([]),
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
        dictationState: CodexComposerDictationState = .init(),
        dictationActions: CodexComposerDictationActions? = nil,
        onStartVoiceChat: (() -> Void)? = nil,
        voiceChatLabel: String = "Start new voice chat",
        composerFocusRequest: Int = 0,
        onSteerQueuedFollowUp: @escaping (String) -> Void = { _ in },
        onRemoveQueuedFollowUp: @escaping (String) -> Void = { _ in },
        onEditQueuedFollowUp: @escaping (String) -> Void = { _ in },
        onSendSideChatMessage: @escaping () -> Void = {},
        onInterruptSideChatMessage: @escaping () -> Void = {},
        onComposerAddMenuRoute: ((CodexComposerAddMenuRoute) -> Void)? = nil,
        onComposerChipClear: ((CodexComposerChipKind) -> Void)? = nil,
        onFilesDropped: (@MainActor @Sendable ([URL]) -> Void)? = nil,
        onEnvironmentHandoffCompletion: (@MainActor @Sendable (CodexWorktreeHandoffCompletion) -> Void)? = nil,
        onOpenThread: @escaping (CodexThreadReferenceV2) -> Void = { _ in },
        onStartReview: @escaping (CodexReviewTarget) -> Void = { _ in },
        onOpenMCPDetails: (() -> Void)? = nil,
        onRefreshMCPServers: (() -> Void)? = nil,
        onToggleSidebar: @escaping () -> Void = {},
        onDisconnect: @escaping () -> Void,
        onPromptSelected: ((String) -> Void)? = nil,
        onSlashCommandSelected: ((CodexSlashCommand) -> Void)? = nil,
        approvalPrompts: [CodexApprovalPrompt] = [],
        onResolveApproval: @escaping (CodexServerRequestKey, Bool) -> Void = { _, _ in },
        showsComposer: Bool = true,
        bottomAccessory: AnyView? = nil,
        supplementalTranscriptTurns: [CodexTurnV2] = [],
        supplementalTranscriptPresentedAtByTurnID: [String: Date] = [:]
    ) {
        self.presentationStore = presentationStore
        self.sideChat = sideChat
        self.subagents = subagents
        self.subagentCoordinator = subagentCoordinator
        self.workspacePath = workspacePath
        self.visualizationRoots = visualizationRoots
        self.chatTitle = chatTitle
        self.currentThreadID = currentThreadID
        self._panel = ObservedObject(wrappedValue: panel)
        self._workspaceTabs = ObservedObject(wrappedValue: panel.workspaceTabs)
        self.mountedPanels = mountedPanels
        self.rateLimitBannerMessage = rateLimitBannerMessage
        self.workspaceSummary = workspaceSummary
        self.threadResourceInventory = threadResourceInventory
        self.onOpenResource = onOpenResource
        self.gitReviewSession = gitReviewSession
        self.backgroundTerminalActions = backgroundTerminalActions
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
        self._isModelMenuPresented = isModelMenuPresented
        self._focusComposerRequest = focusComposerRequest
        self._serviceTierSelection = serviceTierSelection
        self._reasoningSelection = reasoningSelection
        self._draft = draft
        self._referencedFiles = referencedFiles
        self._responseAnnotations = responseAnnotations
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
        self.dictationState = dictationState
        self.dictationActions = dictationActions
        self.onStartVoiceChat = onStartVoiceChat
        self.voiceChatLabel = voiceChatLabel
        self.composerFocusRequest = composerFocusRequest
        self.onSteerQueuedFollowUp = onSteerQueuedFollowUp
        self.onRemoveQueuedFollowUp = onRemoveQueuedFollowUp
        self.onEditQueuedFollowUp = onEditQueuedFollowUp
        self.onSendSideChatMessage = onSendSideChatMessage
        self.onInterruptSideChatMessage = onInterruptSideChatMessage
        self.onComposerAddMenuRoute = onComposerAddMenuRoute
        self.onComposerChipClear = onComposerChipClear
        self.onFilesDropped = onFilesDropped
        self.onEnvironmentHandoffCompletion = onEnvironmentHandoffCompletion
        self.onOpenThread = onOpenThread
        self.onStartReview = onStartReview
        self.onOpenMCPDetails = onOpenMCPDetails
        self.onRefreshMCPServers = onRefreshMCPServers
        self.onToggleSidebar = onToggleSidebar
        self.onDisconnect = onDisconnect
        self.onPromptSelected = onPromptSelected
        self.onSlashCommandSelected = onSlashCommandSelected
        self.approvalPrompts = approvalPrompts
        self.onResolveApproval = onResolveApproval
        self.showsComposer = showsComposer
        self.bottomAccessory = bottomAccessory
        self.supplementalTranscriptTurns = supplementalTranscriptTurns
        self.supplementalTranscriptPresentedAtByTurnID = supplementalTranscriptPresentedAtByTurnID
    }

    public var body: some View {
        GeometryReader { proxy in
            let panelState = CodexWorkspaceResponsivePanelState(
                availableWidth: proxy.size.width,
                sidePanelWidth: panel.panelWidth
            )
            let isDockedOverviewVisible = isSummaryPanelOpen && panelState.supportsDockedOverview(isSidePanelOpen: panel.isAgentPanelOpen)
            let isFloatingOverviewVisible = isCompactSummaryPanelPresented && !isDockedOverviewVisible
            // Float the overview over the main chat column, not the side panel:
            // when the persistent side panel is open, inset past its width.
            let floatingOverviewTrailingInset = 16 + (panelState.usesPersistentSidePanel && panel.isAgentPanelOpen ? panel.panelWidth : 0)

            ZStack(alignment: .trailing) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        mainColumn(
                            panelState: panelState,
                            isDockedOverviewVisible: isDockedOverviewVisible,
                            isOverviewControlActive: isDockedOverviewVisible || isFloatingOverviewVisible
                        )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if panelState.usesPersistentSidePanel, panel.isAgentPanelOpen {
                            agentSidePanel(
                                resizable: true,
                                showsCloseButton: panelState.showsCloseButtonInsideSidePanel,
                                placement: .right
                            )
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }

                    if workspaceTabs.isOpen(in: .bottom) {
                        agentSidePanel(
                            resizable: false,
                            showsCloseButton: true,
                            placement: .bottom
                        )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

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

                    agentSidePanel(
                        resizable: true,
                        showsCloseButton: panelState.showsCloseButtonInsideSidePanel,
                        placement: .right
                    )
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping), value: panel.isAgentPanelOpen)
        .animation(.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping), value: workspaceTabs.snapshot.topology.bottom.isOpen)
        .animation(.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping), value: isCompactSummaryPanelPresented)
        .animation(.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping), value: isSummaryPanelOpen)
        .background(theme.colors.canvas.opacity(0.001))
        .task(id: workspaceTabRegistrationFingerprint) { registerAvailableWorkspaceTabs() }
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

    /// Rebuilds composer state from a previously sent message. Editing leaves it
    /// staged for the user; retry sends it straight back out.
    private func restoreComposer(from rawText: String) {
        guard let decoded = CodexComposerPromptCodec.decode(rawText) else {
            draft = rawText
            referencedFiles = []
            responseAnnotations = []
            return
        }
        draft = decoded.request
        referencedFiles = decoded.files
        responseAnnotations = decoded.responseAnnotations.enumerated().map { index, content in
            CodexResponseTextAnnotation(
                id: "restored-\(index)-\(UUID().uuidString)",
                text: content.text,
                annotation: content.annotation,
                anchor: CodexResponseTextAnchor(
                    renderItemID: "",
                    startOffset: 0,
                    endOffset: 0
                )
            )
        }
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
                supplementalTurns: supplementalTranscriptTurns,
                supplementalPresentedAtByTurnID: supplementalTranscriptPresentedAtByTurnID,
                responseAnnotations: responseAnnotations,
                onUpsertResponseAnnotation: upsertResponseAnnotation,
                onRemoveResponseAnnotation: removeResponseAnnotation,
                onOpenSubagent: { openSubagentTab($0, from: .transcript) },
                onOpenThread: onOpenThread,
                onOpenReviewRequest: reviewPanelAction,
                onOpenVisualization: openVisualizationFromTranscript(path:),
                onEditUserMessage: restoreComposer(from:),
                onRetryTurn: { message in
                    restoreComposer(from: message.rawText)
                    onSend()
                },
                onForkChat: chatActions.forkChat,
                agentDisplayNameByThreadID: Dictionary(
                    uniqueKeysWithValues: subagents.map { ($0.id, $0.name) }
                ),
                agentDisplayStatusByThreadID: Dictionary(
                    uniqueKeysWithValues: subagents.map {
                        ($0.id, $0.status.transcriptDisplayStatus)
                    }
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
            .codexTranscriptFileNavigationService(
                CodexWorkspaceTranscriptFileNavigationService(
                    workspaceURL: URL(fileURLWithPath: workspacePath),
                    openFile: { [weak panel] resolved in
                        guard let panel else { return }
                        let tabID = panel.openFilePreview(fileURL: resolved.fileURL)
                        if let line = resolved.reference.line {
                            panel.workspaceTabs.updateState(
                                CodexFilePreviewTabState(goToLine: line).tabState,
                                for: tabID
                            )
                        }
                        panel.isAgentPanelOpen = true
                    },
                    revealFile: { resolved in
                        NSWorkspace.shared.selectFile(
                            resolved.fileURL.path,
                            inFileViewerRootedAtPath: workspacePath
                        )
                    }
                )
            )
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
                    isPanelOpen: panel.isAnyWorkspacePanelOpen,
                    chatActions: workspaceChatActions,
                    onToggleSidebar: onToggleSidebar,
                    onToggleSummaryPanel: {
                        toggleSummaryPanel(panelState: panelState)
                    },
                    onTogglePanel: toggleAgentPanel,
                    onDisconnect: onDisconnect
                )

                Spacer(minLength: 0)
                if let bottomAccessory {
                    bottomAccessory
                        .offset(x: -contentShift)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: CodexComposerOverlayHeightKey.self,
                                    value: proxy.size.height
                                )
                            }
                        }
                } else if showsComposer {
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
                        responseAnnotations: $responseAnnotations,
                        placeholder: isGoalPursuitEnabled
                            ? "What should Codex keep working toward?"
                            : "Ask Codex anything about this workspace...",
                        approvalSelection: $approvalSelection,
                        isPlanModeEnabled: $isPlanModeEnabled,
                        isGoalPursuitEnabled: isGoalPursuitEnabled,
                        approvalOptions: approvalOptions,
                        modelSelection: $modelSelection,
                        modelOptions: modelOptions,
                        isModelMenuPresented: $isModelMenuPresented,
                        focusRequest: $focusComposerRequest,
                        modelPickerStyle: .grid,
                        serviceTierSelection: $serviceTierSelection,
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
                        dictationState: dictationState,
                        dictationActions: dictationActions,
                        onStartVoiceChat: onStartVoiceChat,
                        voiceChatLabel: voiceChatLabel,
                        onSlashCommandSelected: onSlashCommandSelected,
                        onOpenMCPDetails: onOpenMCPDetails,
                        onRefreshMCPServers: onRefreshMCPServers,
                        onAddMenuRoute: onComposerAddMenuRoute,
                        onComposerChipClear: onComposerChipClear,
                        onFilesDropped: onFilesDropped,
                        voiceFocusRequest: composerFocusRequest
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
            guard let next = CodexComposerOverlayHeightReconciler.next(
                current: composerOverlayHeight,
                proposed: height
            ) else { return }
            composerOverlayHeight = next
        }
    }

    private var dockedOverviewContentShift: CGFloat {
        min(theme.spacing.summaryPanelWidth * 0.38, 120)
    }

    private func upsertResponseAnnotation(_ annotation: CodexResponseTextAnnotation) {
        if let index = responseAnnotations.firstIndex(where: { $0.id == annotation.id }) {
            responseAnnotations[index] = annotation
        } else {
            responseAnnotations.append(annotation)
        }
    }

    private func removeResponseAnnotation(_ id: String) {
        responseAnnotations.removeAll { $0.id == id }
    }

    private var panelTabs: [CodexAgentPanelTab] {
        panel.agentTabs(sideChat: sideChat)
    }

    private var workspaceChatActions: CodexChatActionHandlers {
        var actions = chatActions
        if let openSideChat = chatActions.openSideChat {
            actions.openSideChat = {
                openSideChat()
                openPanelTab(CodexSideChatState.defaultID, from: .commandMenu)
            }
        }
        return actions
    }

    private var floatingSummaryPanel: some View {
        CodexFloatingSummaryPanel(
            sideChat: sideChat,
            subagents: subagents,
            subagentCoordinator: subagentCoordinator,
            threadResourceInventory: effectiveThreadResourceInventory,
            workspaceSummary: workspaceSummary,
            gitReviewSession: gitReviewSession,
            backgroundTerminalActions: backgroundTerminalActions,
            chatTitle: chatTitle,
            onEnvironmentHandoffCompletion: { completion in
                onEnvironmentHandoffCompletion?(completion)
            },
            onOpenPlan: { openPlanPanel() },
            onOpenReview: { openReviewPanel() },
            onOpenBackgroundTerminalDetail: { processID in
                openBackgroundTerminalDetail(processID)
            },
            onOpenResource: openThreadResource,
            onSelectTab: { openPanelTab($0, from: .summary) }
        )
    }

    // Union of tool sessions across all mounted recent chats, kept in one deck so
    // switching chats is a visibility toggle instead of remounting surfaces. The
    // active `panel` is appended last (and always observed) so its sessions stay
    // current; ids dedupe repeats.
    private var mountedWorkspaceTools: CodexMountedWorkspaceToolSessions {
        CodexMountedWorkspaceToolSessions(panels: mountedPanels + [panel])
    }

    private func agentSidePanel(
        resizable: Bool,
        showsCloseButton: Bool,
        placement: CodexWorkspaceTabPlacement
    ) -> some View {
        let mountedTools = mountedWorkspaceTools
        return CodexAgentSidePanel(
            tabs: panelTabs,
            workspaceTabs: workspaceTabs,
            width: resizable ? $panel.panelWidth : .constant(theme.spacing.sidePanelWidth),
            browserSessions: panel.browserSessions,
            mountedBrowserSessions: mountedTools.browser,
            threadResourceInventory: effectiveThreadResourceInventory,
            onOpenResource: openThreadResource,
            modelOptions: modelOptions,
            sideChatDraft: $sideChatDraft,
            isSideChatSending: isSideChatSending,
            canSendSideChatMessage: canSendSideChatMessage,
            onSendSideChatMessage: onSendSideChatMessage,
            onInterruptSideChatMessage: onInterruptSideChatMessage,
            onOpenTerminal: openTerminalTab,
            onOpenBrowser: openBrowserTab,
            onOpenFiles: openFilesTab,
            onCloseBrowser: closeBrowserTab,
            showsCloseButton: showsCloseButton,
            onClose: {
                withAnimation(.spring(
                    response: theme.animations.springResponse,
                    dampingFraction: theme.animations.springDamping
                )) {
                    if placement == .right {
                        panel.isAgentPanelOpen = false
                    } else {
                        workspaceTabs.setOpen(false, placement: placement)
                    }
                }
            },
            placement: placement,
            panelHeight: placement == .bottom ? 280 : 0
        )
    }

    private func compactOverlayBackdrop(onDismiss: @escaping () -> Void) -> some View {
        theme.colors.canvas.opacity(0.42)
            .ignoresSafeArea()
            .onTapGesture(perform: onDismiss)
    }

    private func openPanelTab(
        _ id: String,
        from opener: CodexWorkspaceTabOpener
    ) {
        if sideChat?.id == id {
            workspaceTabs.openLegacy(id)
            showAgentPanel()
            return
        }
        openSubagentTab(id, from: opener)
    }

    private var effectiveThreadResourceInventory: CodexThreadResourceInventory? {
        if let threadResourceInventory { return threadResourceInventory }
        guard let threadID = currentThreadID.flatMap({ ThreadID($0) }),
              let snapshot = presentationStore.activeCanonicalSnapshot
        else { return nil }
        return CodexThreadResourceProjection.project(
            snapshot: snapshot,
            threadID: threadID
        )
    }

    /// Resolves typed inventory requests at the workspace boundary. Resource
    /// adapters own their host-specific route and this method only connects
    /// the already-registered built-ins; unknown resources are handed back to
    /// the host without fabricating a preview surface.
    private func openThreadResource(_ request: CodexWorkspaceTabRequest) {
        if let onOpenResource {
            onOpenResource(request)
            return
        }
        guard let resource = effectiveThreadResourceInventory?.resource(id: request.resourceID) else {
            return
        }
        switch resource.kind {
        case .plan:
            openPlanPanel(request: request)
        case .review:
            openReviewPanel(request: request)
        case .subagent:
            if let childID = resource.metadata.childThreadID {
                openSubagentTab(childID.rawValue, request: request)
            }
        case .backgroundTerminal:
            if let processID = resource.metadata.processID {
                openBackgroundTerminalDetail(processID, request: request)
            }
        case .editedFile, .outputFile, .source:
            guard let path = resource.metadata.path else { return }
            let fileURL = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: workspacePath))
                .standardizedFileURL
            let tabID = panel.openFilePreview(
                fileURL: fileURL,
                opener: request.opener,
                placement: request.placement
            )
            if let line = resource.metadata.line {
                panel.workspaceTabs.updateState(
                    CodexFilePreviewTabState(goToLine: line).tabState,
                    for: tabID
                )
            }
            showAgentPanel()
        case .webActivity:
            if let url = resource.metadata.url ?? resource.metadata.query {
                let browserID = panel.openBrowser()
                panel.browserSessions.first { $0.id == browserID }?.addressText = url
                panel.browserSessions.first { $0.id == browserID }?.navigateToAddressText()
                showAgentPanel()
            }
        case .pullRequest:
            openReviewPanel(request: request)
        case .sideChat:
            if let sideChatID = resource.metadata.sourceID {
                openPanelTab(sideChatID, from: request.opener)
            }
        case .visualization:
            guard let adapter = CodexVisualizationWorkspaceTabAdapter(
                resource: resource,
                workspaceURL: URL(fileURLWithPath: workspacePath),
                visualizationRoots: visualizationRoots,
                frameStore: visualizationFrames
            ) else { return }
            workspaceTabs.open(adapter, request: request)
            showAgentPanel()
        case .generatedImage, .artifact, .mcpResource, .mcpApp, .unknown:
            // These adapters are supplied by later workspace slices. Keep the
            // typed request observable to the host rather than duplicating a
            // preview host here.
            break
        }
    }

    private func openVisualizationFromTranscript(path: String) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let resource = effectiveThreadResourceInventory?.resources.first(where: {
            guard $0.kind == .visualization, let candidate = $0.metadata.path else { return false }
            return URL(fileURLWithPath: candidate).standardizedFileURL.path == normalized
        }) else { return }
        openThreadResource(resource.workspaceTabRequest(opener: .transcript))
    }

    /// Opens the one Subagents workspace tab for a typed child opener. The
    /// child may still be hydrating, so this path intentionally never checks
    /// the currently-loaded metadata arrays and never falls back to a legacy
    /// per-agent tab.
    private func openSubagentTab(
        _ id: String,
        from opener: CodexWorkspaceTabOpener
    ) {
        guard let adapter = subagentsAdapter else { return }
        workspaceTabs.open(
            CodexSubagentsWorkspaceTabAdapter(
                parentThreadID: adapter.parentThreadID,
                coordinator: adapter.coordinator,
                selectedThreadID: id
            ),
            from: opener
        )
        isCompactSummaryPanelPresented = false
        showAgentPanel()
    }

    private func openSubagentTab(
        _ id: String,
        request: CodexWorkspaceTabRequest
    ) {
        guard let adapter = subagentsAdapter else { return }
        workspaceTabs.open(
            CodexSubagentsWorkspaceTabAdapter(
                parentThreadID: adapter.parentThreadID,
                coordinator: adapter.coordinator,
                selectedThreadID: id
            ),
            request: request
        )
        isCompactSummaryPanelPresented = false
        showAgentPanel()
    }

    private func openReviewPanel(_ request: CodexTranscriptReviewRequest) {
        workspaceTabs.open(
            reviewAdapter(
                session: request.session,
                source: .transcript,
                selectedFilePath: request.selectedFilePath
            ),
            from: .transcript
        )
        showAgentPanel()
    }

    private func openPlanPanel(request: CodexWorkspaceTabRequest? = nil) {
        guard let plan = workspaceSummary?.plan else { return }
        let adapter = CodexPlanWorkspaceTabAdapter(plan: plan)
        if let request {
            workspaceTabs.open(adapter, request: request)
        } else {
            workspaceTabs.open(adapter, from: .summary)
        }
        showAgentPanel()
    }

    private func openReviewPanel(request: CodexWorkspaceTabRequest? = nil) {
        guard let session = gitReviewSession else { return }
        let adapter = reviewAdapter(session: session)
        if let request {
            workspaceTabs.open(adapter, request: request)
        } else {
            workspaceTabs.open(adapter, from: .summary)
        }
        showAgentPanel()
    }

    private var reviewPanelAction: (CodexTranscriptReviewRequest) -> Void {
        openReviewPanel
    }

    private var workspaceTabRegistrationFingerprint: String {
        let plan = workspaceSummary?.plan.map {
            [$0.explanation ?? ""] + $0.steps.map {
                "\($0.step):\($0.status)"
            }
        }?.joined(separator: "|") ?? "no-plan"
        let review = gitReviewSession.map {
            "\($0.snapshot.revision.sourceID):\($0.snapshot.revision.value)"
        } ?? "no-review"
        let subagentIdentity = subagentCoordinator != nil
            ? (currentThreadID ?? "no-thread")
            : "no-subagent-coordinator"
        let routes = workspaceTabs.snapshot.instances.map {
            "\($0.resourceKey):\($0.durableRoute?.resourceID ?? "")"
        }.joined(separator: "|")
        let backgroundTerminals = workspaceSummary?.backgroundTerminals.map { state in
            "\(state.lastChangedRevision.rawValue):"
                + state.terminals.map { "\($0.processID):\($0.command)" }.joined(separator: ",")
        } ?? "no-background-terminals"
        let visualizationRootIdentity = visualizationRoots
            .map { $0.standardizedFileURL.path }
            .sorted()
            .joined(separator: ",")
        let visualizations = effectiveThreadResourceInventory?
            .resources(of: .visualization)
            .map { "\($0.id):\($0.metadata.path ?? ""):\($0.status.rawValue)" }
            .joined(separator: ",") ?? "no-visualizations"
        return "\(workspacePath)|\(visualizationRootIdentity)|\(visualizations)|\(plan)|\(review)|\(subagentIdentity)|\(routes)|\(backgroundTerminals)"
    }

    private func registerAvailableWorkspaceTabs() {
        var adapters: [any CodexWorkspaceTabAdapter] = panel.terminalWorkspaceTabAdapters
        if let plan = workspaceSummary?.plan {
            adapters.append(CodexPlanWorkspaceTabAdapter(plan: plan))
        }
        if let session = gitReviewSession {
            adapters.append(reviewAdapter(session: session))
            adapters.append(reviewAdapter(session: session, source: .transcript))
        }
        if let adapter = subagentsAdapter {
            adapters.append(adapter)
        }
        if let backgroundTerminals = workspaceSummary?.backgroundTerminals {
            adapters.append(contentsOf: backgroundTerminals.terminals.map { terminal in
                CodexBackgroundTerminalWorkspaceTabAdapter(
                    threadID: backgroundTerminals.threadID,
                    terminal: terminal,
                    onTerminate: {
                        backgroundTerminalActions?.terminate(terminal.processID)
                    }
                )
            })
        }
        let fileAdapters = CodexFilesWorkspaceTabAdapterRegistry.make(
            snapshot: workspaceTabs.snapshot,
            workspaceURL: URL(fileURLWithPath: workspacePath),
            existingSession: panel.filesSession,
            onOpenFile: { [weak panel] url in
                _ = panel?.openFilePreview(fileURL: url)
            },
            onSessionClosed: { [weak panel] session in
                guard panel?.filesSession?.id == session.id else { return }
                panel?.filesSession = nil
            }
        )
        panel.reconcileFilesSession(fileAdapters.filesSession)
        adapters.append(contentsOf: fileAdapters.adapters)
        adapters.append(contentsOf: CodexVisualizationWorkspaceTabAdapterRegistry.make(
            resources: effectiveThreadResourceInventory?.resources(of: .visualization) ?? [],
            snapshot: workspaceTabs.snapshot,
            workspaceURL: URL(fileURLWithPath: workspacePath),
            visualizationRoots: visualizationRoots,
            frameStore: visualizationFrames
        ))
        workspaceTabs.register(adapters)
    }

    private func openBackgroundTerminalDetail(
        _ processID: String,
        request: CodexWorkspaceTabRequest? = nil
    ) {
        guard let backgroundTerminals = workspaceSummary?.backgroundTerminals,
              let terminal = backgroundTerminals.terminals.first(
            where: { $0.processID == processID }
        ) else { return }
        let adapter = CodexBackgroundTerminalWorkspaceTabAdapter(
                threadID: backgroundTerminals.threadID,
                terminal: terminal,
                onTerminate: {
                    backgroundTerminalActions?.terminate(processID)
                }
            )
        if let request {
            workspaceTabs.open(adapter, request: request)
        } else {
            workspaceTabs.open(adapter, from: .summary)
        }
        showAgentPanel()
    }

    private var subagentsAdapter: CodexSubagentsWorkspaceTabAdapter? {
        guard let subagentCoordinator, let currentThreadID else { return nil }
        return CodexSubagentsWorkspaceTabAdapter(
            parentThreadID: currentThreadID,
            coordinator: subagentCoordinator
        )
    }

    private func reviewAdapter(
        session: CodexGitReviewSession,
        source: CodexReviewWorkspaceTabAdapter.Source = .workspace,
        selectedFilePath: String? = nil
    ) -> CodexReviewWorkspaceTabAdapter {
        CodexReviewWorkspaceTabAdapter(
            workspaceURL: URL(fileURLWithPath: workspacePath),
            session: session,
            source: source,
            selectedFilePath: selectedFilePath,
            onStartReview: onStartReview
        )
    }

    private func showAgentPanel() {
        isCompactSummaryPanelPresented = false
        withAnimation(.spring(
            response: theme.animations.springResponse,
            dampingFraction: theme.animations.springDamping
        )) {
            panel.isAgentPanelOpen = true
        }
    }

    private func toggleAgentPanel() {
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
    }

    private func openBrowserTab() {
        panel.openBrowser()
        withAnimation(.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping)) {
            panel.isAgentPanelOpen = true
        }
    }

    private func closeBrowserTab(_ id: String) {
        panel.closeBrowser(id: id)
    }

    private func openFilesTab() {
        panel.openFiles(workspacePath: workspacePath)
        withAnimation(.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping)) {
            panel.isAgentPanelOpen = true
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
        // One container for every bubble in the row, so the system renders them
        // in a single pass. Zero merge spacing keeps separated controls distinct
        // at rest while still allowing overlapping transition shapes to morph.
        CodexGlassGroup(spacing: 0) {
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
}

/// A floating glass capsule that groups one or more header controls, à la the
/// macOS Notes/Reminders toolbar bubbles.
///
/// Carries no stroke and no shadow of its own: Liquid Glass draws both, and
/// hand-drawn copies on top are what make glass read as an imitation.
private struct HeaderBubble<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 2) {
            content
        }
        .padding(.horizontal, 4)
        .frame(height: 34)
        .codexGlass(Capsule(), role: .controlGroup)
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

private extension CodexSubagentState.Status {
    var transcriptDisplayStatus: CodexAgentDisplayStatusV2 {
        switch self {
        case .running: .working
        case .completed: .done
        case .closed: .closed
        case .failed: .failed
        }
    }
}
