import SwiftUI
import CodexCore

/// A complete reusable Codex chat workspace: transcript, header, composer, and session sidebar.
public struct CodexChatWorkspaceView: View {
    @Environment(\.codexAgentTheme) private var theme

    private let messages: [CodexChatMessage]
    private let lifecycleEvents: [CodexAgentLifecycleEvent]
    private let sideChat: CodexSideChatState?
    private let subagents: [CodexSubagentState]
    private let activities: [CodexActivity]
    private let connectionState: CodexConnectionState
    private let workspacePath: String
    private let showsSidebarToggle: Bool
    private let isSidebarVisible: Bool
    private let chatActions: CodexChatActionHandlers
    private let approvalOptions: [CodexApprovalSelection]
    private let modelOptions: [CodexModelSelection]
    private let slashCommands: [CodexSlashCommand]
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
    private let followUpHint: String?
    private let mentionResults: [FuzzyFileSearchResult]
    private let onMentionQueryChanged: ((String?) -> Void)?
    private let onMentionSelected: ((FuzzyFileSearchResult) -> Void)?
    private let onSend: () -> Void
    private let onInterrupt: () -> Void
    private let onSendSideChatMessage: () -> Void
    private let onInterruptSideChatMessage: () -> Void
    private let onToggleSidebar: () -> Void
    private let onDisconnect: () -> Void
    private let onPromptSelected: ((String) -> Void)?
    private let onSlashCommandSelected: ((CodexSlashCommand) -> Void)?
    @State private var isAgentPanelOpen = false
    @State private var isSummaryPanelOpen = true
    @State private var selectedPanelTabID: String?
    @State private var agentPanelWidth: CGFloat = 360

    public init(
        messages: [CodexChatMessage],
        lifecycleEvents: [CodexAgentLifecycleEvent] = [],
        sideChat: CodexSideChatState? = nil,
        subagents: [CodexSubagentState] = [],
        activities: [CodexActivity],
        connectionState: CodexConnectionState,
        workspacePath: String,
        showsSidebarToggle: Bool = false,
        isSidebarVisible: Bool = false,
        chatActions: CodexChatActionHandlers = CodexChatActionHandlers(),
        approvalOptions: [CodexApprovalSelection] = CodexApprovalSelection.defaultOptions,
        modelOptions: [CodexModelSelection] = CodexModelSelection.defaultOptions,
        slashCommands: [CodexSlashCommand] = CodexSlashCommand.observedCommands,
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
        followUpHint: String? = nil,
        mentionResults: [FuzzyFileSearchResult] = [],
        onMentionQueryChanged: ((String?) -> Void)? = nil,
        onMentionSelected: ((FuzzyFileSearchResult) -> Void)? = nil,
        onSend: @escaping () -> Void,
        onInterrupt: @escaping () -> Void,
        onSendSideChatMessage: @escaping () -> Void = {},
        onInterruptSideChatMessage: @escaping () -> Void = {},
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
        self.showsSidebarToggle = showsSidebarToggle
        self.isSidebarVisible = isSidebarVisible
        self.chatActions = chatActions
        self.approvalOptions = approvalOptions
        self.modelOptions = modelOptions
        self.slashCommands = slashCommands
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
        self.followUpHint = followUpHint
        self.mentionResults = mentionResults
        self.onMentionQueryChanged = onMentionQueryChanged
        self.onMentionSelected = onMentionSelected
        self.onSend = onSend
        self.onInterrupt = onInterrupt
        self.onSendSideChatMessage = onSendSideChatMessage
        self.onInterruptSideChatMessage = onInterruptSideChatMessage
        self.onToggleSidebar = onToggleSidebar
        self.onDisconnect = onDisconnect
        self.onPromptSelected = onPromptSelected
        self.onSlashCommandSelected = onSlashCommandSelected
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    mainColumn
                }

                if isAgentPanelOpen, !panelTabs.isEmpty {
                    CodexAgentSidePanel(
                        tabs: panelTabs,
                        selectedTabID: $selectedPanelTabID,
                        width: $agentPanelWidth,
                        sideChatDraft: $sideChatDraft,
                        isSideChatSending: isSideChatSending,
                        canSendSideChatMessage: canSendSideChatMessage,
                        onSendSideChatMessage: onSendSideChatMessage,
                        onInterruptSideChatMessage: onInterruptSideChatMessage,
                        onClose: { withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { isAgentPanelOpen = false } }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }

            if isSummaryPanelOpen {
                CodexFloatingSummaryPanel(
                    sideChat: sideChat,
                    subagents: subagents,
                    onSelectTab: openPanelTab
                )
                .padding(.top, 58)
                .padding(.trailing, isAgentPanelOpen ? agentPanelWidth + 16 : 16)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing)))
                .animation(.spring(response: 0.32, dampingFraction: 0.9), value: isAgentPanelOpen)
            }
        }
        .background(theme.colors.canvas.opacity(0.001))
    }

    private var mainColumn: some View {
        ZStack(alignment: .top) {
            CodexTranscriptView(messages: messages, lifecycleEvents: lifecycleEvents) {
                CodexEmptyTranscriptView { prompt in
                    if let onPromptSelected {
                        onPromptSelected(prompt)
                    } else {
                        draft = prompt
                    }
                }
            }
            .safeAreaPadding(.top, 58)
            .safeAreaPadding(.bottom, 122)

            VStack(spacing: 0) {
                CodexChatHeader(
                    workspacePath: workspacePath,
                    connectionState: connectionState,
                    activities: activities,
                    showsSidebarToggle: showsSidebarToggle,
                    isSidebarVisible: isSidebarVisible,
                    isSummaryPanelOpen: isSummaryPanelOpen,
                    hasPanelTabs: !panelTabs.isEmpty,
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
                if isSending {
                    CodexInlineChatStatus(activity: activities.first, onInterrupt: onInterrupt)
                        .frame(maxWidth: theme.spacing.composerMaxWidth + 32, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.bottom, -1)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                CodexComposerBar(
                    draft: $draft,
                    approvalSelection: $approvalSelection,
                    isPlanModeEnabled: $isPlanModeEnabled,
                    approvalOptions: approvalOptions,
                    modelSelection: $modelSelection,
                    modelOptions: modelOptions,
                    reasoningSelection: $reasoningSelection,
                    slashCommands: slashCommands,
                    isSending: isSending,
                    canSend: canSend,
                    canUsePlanMode: canUsePlanMode,
                    followUpHint: followUpHint,
                    mentionResults: mentionResults,
                    onMentionQueryChanged: onMentionQueryChanged,
                    onMentionSelected: onMentionSelected,
                    onSend: onSend,
                    onInterrupt: onInterrupt,
                    onSlashCommandSelected: onSlashCommandSelected
                )
                .frame(maxWidth: theme.spacing.composerMaxWidth + 32)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
        .frame(minWidth: 540)
    }

    private var panelTabs: [CodexAgentPanelTab] {
        var tabs: [CodexAgentPanelTab] = []
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

    private func openPanelTab(_ id: String) {
        selectedPanelTabID = id
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
            isAgentPanelOpen = true
        }
    }

    private func toggleAgentPanel() {
        if selectedPanelTabID == nil { selectedPanelTabID = panelTabs.first?.id }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
            isAgentPanelOpen.toggle()
        }
    }
}

public struct CodexChatHeader: View {
    @Environment(\.codexAgentTheme) private var theme

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
        workspacePath: String,
        connectionState: CodexConnectionState,
        activities: [CodexActivity] = [],
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

            ToolbarIconButton(systemImage: "chevron.left", help: "Back") {}
                .disabled(true)
            ToolbarIconButton(systemImage: "chevron.right", help: "Forward") {}
                .disabled(true)

            ToolbarIconButton(systemImage: "square.and.pencil", help: "New chat") {}

            Divider()
                .overlay(theme.colors.border)
                .frame(height: 22)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 0) {
                Text("Codex")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 8.5))
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
                help: "Toggle summary",
                action: onToggleSummaryPanel
            )

            ToolbarIconButton(
                systemImage: "sidebar.right",
                isActive: isPanelOpen,
                isEnabled: hasPanelTabs,
                help: "Toggle side chat",
                action: onTogglePanel
            )

            ToolbarIconButton(systemImage: "xmark", help: "Disconnect", action: onDisconnect)
        }
        .frame(height: theme.spacing.toolbarHeight)
        .padding(.horizontal, 10)
        .background(theme.colors.surface.opacity(0.92))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.colors.border)
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isEnabled ? theme.colors.textSecondary : theme.colors.textTertiary.opacity(0.6))
                .frame(width: 28, height: 28)
                .background(
                    isActive ? theme.colors.surfaceElevated.opacity(0.82) : .clear,
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
            actionButton("Pin chat", action: actions.pinChat)
            actionButton("Rename chat", action: actions.renameChat)
            actionButton("Archive chat", action: actions.archiveChat)
            Divider()
            actionButton("Open side chat", action: actions.openSideChat)
            actionButton("Copy", action: actions.copyChat)
            actionButton("Fork", action: actions.forkChat)
            Divider()
            actionButton("Add automation...", action: actions.addAutomation)
            actionButton("Open in new window", action: actions.openInNewWindow)
            Divider()
            Button("Disconnect", action: onDisconnect)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(theme.colors.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
        }
        .fixedSize()
        .help("Chat actions")
    }

    private func actionButton(_ title: String, action: (() -> Void)?) -> some View {
        Button(title) { action?() }
            .disabled(action == nil)
    }
}

private func codexShortPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
    return path
}

public struct CodexComposerBar: View {
    @Environment(\.codexAgentTheme) private var theme

    @Binding private var draft: String
    @Binding private var approvalSelection: CodexApprovalSelection
    @Binding private var isPlanModeEnabled: Bool
    private let approvalOptions: [CodexApprovalSelection]
    @Binding private var modelSelection: CodexModelSelection
    private let modelOptions: [CodexModelSelection]
    @Binding private var reasoningSelection: CodexReasoningSelection
    private let slashCommands: [CodexSlashCommand]
    private let isSending: Bool
    private let canSend: Bool
    private let canUsePlanMode: Bool
    private let followUpHint: String?
    private let mentionResults: [FuzzyFileSearchResult]
    private let onMentionQueryChanged: ((String?) -> Void)?
    private let onMentionSelected: ((FuzzyFileSearchResult) -> Void)?
    private let onSend: () -> Void
    private let onInterrupt: () -> Void
    private let onSlashCommandSelected: ((CodexSlashCommand) -> Void)?
    @FocusState private var focused: Bool

    public init(
        draft: Binding<String>,
        approvalSelection: Binding<CodexApprovalSelection> = .constant(.fullAccess),
        isPlanModeEnabled: Binding<Bool> = .constant(false),
        approvalOptions: [CodexApprovalSelection] = CodexApprovalSelection.defaultOptions,
        modelSelection: Binding<CodexModelSelection> = .constant(.appServerDefault),
        modelOptions: [CodexModelSelection] = CodexModelSelection.defaultOptions,
        reasoningSelection: Binding<CodexReasoningSelection> = .constant(.medium),
        slashCommands: [CodexSlashCommand] = CodexSlashCommand.observedCommands,
        isSending: Bool,
        canSend: Bool,
        canUsePlanMode: Bool = true,
        followUpHint: String? = nil,
        mentionResults: [FuzzyFileSearchResult] = [],
        onMentionQueryChanged: ((String?) -> Void)? = nil,
        onMentionSelected: ((FuzzyFileSearchResult) -> Void)? = nil,
        onSend: @escaping () -> Void,
        onInterrupt: @escaping () -> Void,
        onSlashCommandSelected: ((CodexSlashCommand) -> Void)? = nil
    ) {
        self._draft = draft
        self._approvalSelection = approvalSelection
        self._isPlanModeEnabled = isPlanModeEnabled
        self.approvalOptions = approvalOptions
        self._modelSelection = modelSelection
        self.modelOptions = modelOptions
        self._reasoningSelection = reasoningSelection
        self.slashCommands = slashCommands
        self.isSending = isSending
        self.canSend = canSend
        self.canUsePlanMode = canUsePlanMode
        self.followUpHint = followUpHint
        self.mentionResults = mentionResults
        self.onMentionQueryChanged = onMentionQueryChanged
        self.onMentionSelected = onMentionSelected
        self.onSend = onSend
        self.onInterrupt = onInterrupt
        self.onSlashCommandSelected = onSlashCommandSelected
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let slashQuery, !filteredSlashCommands.isEmpty {
                CodexSlashCommandPalette(
                    commands: filteredSlashCommands,
                    query: slashQuery,
                    onSelect: selectSlashCommand
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if mentionQuery != nil, !mentionResults.isEmpty {
                CodexMentionPalette(results: mentionResults, onSelect: selectMention)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            VStack(spacing: 8) {
                TextField("Ask Codex anything about this workspace...", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(theme.fonts.chat)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit(onSend)
                    .padding(.leading, 6)
                    .padding(.vertical, 6)

                HStack(spacing: 8) {
                    ComposerAddMenu(isPlanModeEnabled: $isPlanModeEnabled, canUsePlanMode: canUsePlanMode)
                    ComposerApprovalMenu(selection: $approvalSelection, options: approvalOptions)
                    ComposerModelMenu(model: $modelSelection, modelOptions: modelOptions, reasoning: $reasoningSelection)

                    Spacer(minLength: 0)

                    if let followUpHint {
                        Text(followUpHint)
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.textTertiary)
                            .lineLimit(1)
                            .transition(.opacity)
                    }

                    ComposerIconButton(systemImage: "waveform", help: "Dictate") {}

                    if isSending {
                        // The composer stays live during a run: send steers or
                        // queues the draft, stop interrupts the turn.
                        SendButton(enabled: canSend, action: onSend)
                        ComposerStopButton(action: onInterrupt)
                    } else {
                        SendButton(enabled: canSend, action: onSend)
                    }
                }
            }
            .padding(10)
            .codexGlass(RoundedRectangle(cornerRadius: theme.radii.composer, style: .continuous))
        }
        .onAppear { focused = true }
        .onChange(of: mentionQuery) { _, query in
            onMentionQueryChanged?(query)
        }
    }

    private var slashQuery: String? {
        CodexSlashCommand.query(from: draft)
    }

    private var mentionQuery: String? {
        CodexMentionQuery.query(from: draft)
    }

    private var filteredSlashCommands: [CodexSlashCommand] {
        CodexSlashCommand.filteredCommands(from: slashCommands, matching: draft)
    }

    private func selectSlashCommand(_ command: CodexSlashCommand) {
        draft = command.draftText ?? ""
        onSlashCommandSelected?(command)
    }

    private func selectMention(_ result: FuzzyFileSearchResult) {
        draft = CodexMentionQuery.applyingSelection(result.fileName, to: draft)
        onMentionSelected?(result)
    }
}

private struct ComposerAddMenu: View {
    @Environment(\.codexAgentTheme) private var theme
    @Binding var isPlanModeEnabled: Bool
    let canUsePlanMode: Bool

    var body: some View {
        Menu {
            Button("Add photos & files") {}
            Button("Attach Google Chrome") {}
            Divider()
            Toggle("Plan mode", isOn: $isPlanModeEnabled)
                .disabled(!canUsePlanMode)
            Toggle("Pursue goal", isOn: .constant(false))
            Toggle("Plugins", isOn: .constant(true))
        } label: {
            ComposerChipLabel(systemImage: "plus", title: nil)
        }
        .fixedSize()
        .help("Add files and more")
    }
}

private struct ComposerApprovalMenu: View {
    @Binding var selection: CodexApprovalSelection
    let options: [CodexApprovalSelection]

    var body: some View {
        Menu {
            Text("How should Codex actions be approved?")
            Divider()
            ForEach(availableOptions) { option in
                Button {
                    selection = option
                } label: {
                    if selection == option {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
            }
        } label: {
            ComposerChipLabel(systemImage: "checkmark.seal.fill", title: selection.displayName)
        }
        .fixedSize()
        .help("Approval mode")
    }

    private var availableOptions: [CodexApprovalSelection] {
        options.isEmpty ? CodexApprovalSelection.defaultOptions : options
    }
}

private struct ComposerModelMenu: View {
    @Binding var model: CodexModelSelection
    let modelOptions: [CodexModelSelection]
    @Binding var reasoning: CodexReasoningSelection

    var body: some View {
        Menu {
            Section("Reasoning") {
                ForEach(availableReasoningOptions) { option in
                    Button {
                        reasoning = option
                    } label: {
                        if reasoning == option {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            }
            Divider()
            ForEach(availableModelOptions) { option in
                Button {
                    model = option
                    reconcileReasoning(for: option)
                } label: {
                    if model == option {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
            }
        } label: {
            ComposerChipLabel(systemImage: "sparkles", title: "\(model.displayName) \(reasoning.displayName)")
        }
        .fixedSize()
        .help("Model and reasoning")
        .onChange(of: model) { _, newModel in
            reconcileReasoning(for: newModel)
        }
    }

    private var availableModelOptions: [CodexModelSelection] {
        modelOptions.isEmpty ? CodexModelSelection.defaultOptions : modelOptions
    }

    private var availableReasoningOptions: [CodexReasoningSelection] {
        model.supportedReasoning.isEmpty ? CodexReasoningSelection.defaultOptions : model.supportedReasoning
    }

    private func reconcileReasoning(for model: CodexModelSelection) {
        let supported = model.supportedReasoning.isEmpty ? CodexReasoningSelection.defaultOptions : model.supportedReasoning
        if supported.contains(reasoning) { return }
        if let defaultReasoning = model.defaultReasoning, supported.contains(defaultReasoning) {
            reasoning = defaultReasoning
        } else {
            reasoning = supported.first ?? .medium
        }
    }
}

private struct ComposerChipLabel: View {
    @Environment(\.codexAgentTheme) private var theme

    let systemImage: String
    let title: String?

    var body: some View {
        HStack(spacing: title == nil ? 0 : 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            if let title {
                Text(title)
                    .font(theme.fonts.caption.weight(.medium))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(theme.colors.textSecondary)
        .frame(minWidth: title == nil ? 28 : 0, minHeight: 28)
        .padding(.horizontal, title == nil ? 0 : 10)
        .background(theme.colors.surfaceSunken.opacity(0.72), in: Capsule())
        .overlay(Capsule().stroke(theme.colors.border, lineWidth: 1))
        .contentShape(Capsule())
    }
}

private struct ComposerIconButton: View {
    @Environment(\.codexAgentTheme) private var theme

    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.colors.textSecondary)
                .frame(width: 30, height: 30)
                .background(theme.colors.surfaceSunken.opacity(0.58), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct CodexInlineChatStatus: View {
    @Environment(\.codexAgentTheme) private var theme

    let activity: CodexActivity?
    let onInterrupt: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "target")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.colors.textTertiary)

            HStack(spacing: 5) {
                Text(title)
                    .foregroundStyle(theme.colors.textPrimary)
                if let detail {
                    Text(detail)
                        .foregroundStyle(theme.colors.textTertiary)
                }
                CodexStreamingDots()
            }
            .font(theme.fonts.chat.weight(.medium))
            .lineLimit(1)

            Spacer(minLength: 12)

            InlineStatusIconButton(systemImage: "pencil", help: "Edit objective") {}
                .disabled(true)
            InlineStatusIconButton(systemImage: "pause.circle", help: "Pause", action: onInterrupt)
            InlineStatusIconButton(systemImage: "trash", help: "Clear") {}
                .disabled(true)
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .background(theme.colors.surface.opacity(0.88))
        .overlay(Rectangle().stroke(theme.colors.border, lineWidth: 1))
        .accessibilityLabel(activity?.title ?? "Codex is working")
    }

    private var title: String {
        activity?.title ?? "Codex is working"
    }

    private var detail: String? {
        guard let activity else { return nil }
        let value = activity.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }
        return value
    }
}

private struct InlineStatusIconButton: View {
    @Environment(\.codexAgentTheme) private var theme

    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.colors.textTertiary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct ComposerStopButton: View {
    @Environment(\.codexAgentTheme) private var theme

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "stop.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.colors.danger)
                .frame(width: 34, height: 34)
                .background(theme.colors.surfaceSunken.opacity(0.84), in: Circle())
                .overlay(Circle().stroke(theme.colors.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Stop")
    }
}

/// Parses the trailing `@…` token from a draft, e.g. "fix @clien" → "clien".
public enum CodexMentionQuery {
    public static func query(from draft: String) -> String? {
        guard let atIndex = draft.lastIndex(of: "@") else { return nil }
        // The token must start the draft or follow whitespace.
        if atIndex > draft.startIndex {
            let previous = draft[draft.index(before: atIndex)]
            guard previous.isWhitespace || previous.isNewline else { return nil }
        }
        let token = draft[draft.index(after: atIndex)...]
        guard !token.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return String(token)
    }

    /// Replaces the trailing `@token` in the draft with `@fileName `.
    public static func applyingSelection(_ fileName: String, to draft: String) -> String {
        guard let atIndex = draft.lastIndex(of: "@") else { return draft }
        return String(draft[..<atIndex]) + "@\(fileName) "
    }
}

private struct CodexMentionPalette: View {
    @Environment(\.codexAgentTheme) private var theme

    let results: [FuzzyFileSearchResult]
    let onSelect: (FuzzyFileSearchResult) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Files")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(theme.colors.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)

                ForEach(results.prefix(8)) { result in
                    Button {
                        onSelect(result)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: result.matchType == .directory ? "folder" : "doc.text")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.colors.textTertiary)
                                .frame(width: 18)
                            Text(result.fileName)
                                .font(theme.fonts.caption.weight(.semibold))
                                .foregroundStyle(theme.colors.textPrimary)
                            Text(result.path)
                                .font(theme.fonts.caption)
                                .foregroundStyle(theme.colors.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .frame(height: 29)
                        .padding(.horizontal, 10)
                        .background(
                            result.id == results.first?.id ? theme.colors.surfaceElevated.opacity(0.72) : .clear,
                            in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(result.absolutePath)
                }
            }
            .padding(8)
        }
        .frame(maxWidth: 736, alignment: .leading)
        .frame(maxHeight: 280, alignment: .top)
        .codexGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct CodexSlashCommandPalette: View {
    @Environment(\.codexAgentTheme) private var theme

    let commands: [CodexSlashCommand]
    let query: String
    let onSelect: (CodexSlashCommand) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(sectionNames, id: \.self) { section in
                    if section != sectionNames.first {
                        Text(section)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(theme.colors.textTertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 4)
                    }

                    ForEach(commands.filter { $0.section == section }) { command in
                        Button {
                            onSelect(command)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: command.systemImage)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(theme.colors.textTertiary)
                                    .frame(width: 18)
                                Text(command.title)
                                    .font(theme.fonts.caption.weight(.semibold))
                                    .foregroundStyle(theme.colors.textPrimary)
                                Text(command.detail)
                                    .font(theme.fonts.caption)
                                    .foregroundStyle(theme.colors.textTertiary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if let scopeBadge = command.scopeBadge {
                                    Text(scopeBadge)
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(theme.colors.textTertiary)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(theme.colors.surfaceSunken.opacity(0.72), in: Capsule())
                                }
                            }
                            .frame(height: 29)
                            .padding(.horizontal, 10)
                            .background(
                                command.id == highlightedCommandID ? theme.colors.surfaceElevated.opacity(0.72) : .clear,
                                in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .help(command.detail)
                    }
                }
            }
            .padding(8)
        }
        .frame(maxWidth: 736, alignment: .leading)
        .frame(maxHeight: 320, alignment: .top)
        .codexGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var highlightedCommandID: String? {
        if query.isEmpty { return commands.first?.id }
        return commands.first?.id
    }

    private var sectionNames: [String] {
        var names: [String] = []
        for command in commands where !names.contains(command.section) {
            names.append(command.section)
        }
        return names
    }
}

private struct SendButton: View {
    @Environment(\.codexAgentTheme) private var theme

    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(enabled ? theme.colors.onAccent : theme.colors.textTertiary)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .background {
            if enabled {
                Circle().fill(theme.colors.accent)
            } else {
                Circle().fill(theme.colors.surfaceSunken)
            }
        }
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(!enabled)
        .animation(.snappy(duration: 0.2), value: enabled)
    }
}

public struct CodexSessionSidebar: View {
    private let serverName: String?
    private let workspacePath: String
    private let authLabel: String
    private let isAuthenticated: Bool
    private let isThreadReady: Bool
    private let activities: [CodexActivity]

    public init(
        serverName: String?,
        workspacePath: String,
        authLabel: String,
        isAuthenticated: Bool,
        isThreadReady: Bool,
        activities: [CodexActivity]
    ) {
        self.serverName = serverName
        self.workspacePath = workspacePath
        self.authLabel = authLabel
        self.isAuthenticated = isAuthenticated
        self.isThreadReady = isThreadReady
        self.activities = activities
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CodexTheme.Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SESSION")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(CodexTheme.tertiary)
                Text(serverName ?? "Codex")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CodexTheme.primary)
            }

            VStack(spacing: 8) {
                SidebarFact(icon: "folder.fill", title: "Workspace", value: workspacePath, mono: true)
                SidebarFact(icon: "person.badge.key.fill", title: "Auth", value: isAuthenticated ? authLabel : "Sign-in required")
                SidebarFact(icon: "bubble.left.and.text.bubble.right.fill", title: "Thread", value: isThreadReady ? "Ready" : "Not started")
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("RECENT ACTIVITY")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(CodexTheme.tertiary)

                if activities.isEmpty {
                    Text("Activity appears here while Codex works.")
                        .font(.system(size: 12))
                        .foregroundStyle(CodexTheme.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView(showsIndicators: false) {
                        CodexActivityTimeline(activities: Array(activities.prefix(14)))
                    }
                }
            }
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct SidebarFact: View {
    let icon: String
    let title: String
    let value: String
    var mono = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.accent)
                .frame(width: 16, height: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CodexTheme.secondary)
                Text(value)
                    .font(.system(size: 11.5, design: mono ? .monospaced : .default))
                    .foregroundStyle(CodexTheme.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodexTheme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: CodexTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.Radius.md, style: .continuous)
                .stroke(CodexTheme.stroke, lineWidth: 1)
        )
    }
}

public struct CodexActivityTimeline: View {
    private let activities: [CodexActivity]

    public init(activities: [CodexActivity]) {
        self.activities = activities
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(activities.enumerated()), id: \.element.id) { index, activity in
                ActivityRow(
                    activity: activity,
                    isFirst: index == 0,
                    isLast: index == activities.count - 1
                )
            }
        }
    }
}

private struct ActivityRow: View {
    let activity: CodexActivity
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : CodexTheme.stroke)
                    .frame(width: 1.5, height: 8)
                ZStack {
                    Circle()
                        .fill(activity.kind.tint.opacity(0.16))
                        .frame(width: 22, height: 22)
                    Image(systemName: activity.kind.systemImage)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(activity.kind.tint)
                }
                Rectangle()
                    .fill(isLast ? Color.clear : CodexTheme.stroke)
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(activity.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CodexTheme.primary)
                    Spacer(minLength: 0)
                    Text(activity.createdAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .font(.system(size: 10))
                        .foregroundStyle(CodexTheme.tertiary)
                        .lineLimit(1)
                }
                if !activity.detail.isEmpty {
                    Text(activity.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(CodexTheme.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, isLast ? 0 : 12)
        }
    }
}
