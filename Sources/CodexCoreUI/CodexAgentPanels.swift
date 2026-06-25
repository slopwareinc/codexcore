import SwiftUI

public struct CodexFloatingSummaryPanel: View {
    @Environment(\.codexAgentTheme) private var theme

    private let sideChat: CodexSideChatState?
    private let subagents: [CodexSubagentState]
    private let workspaceSummary: CodexWorkspaceSummaryContext?
    private let gitReviewSession: CodexGitReviewSession?
    private let chatTitle: String
    private let onEnvironmentHandoffCompletion: @MainActor @Sendable (CodexWorktreeHandoffCompletion) -> Void
    private let onSelectTab: (String) -> Void

    public init(
        sideChat: CodexSideChatState?,
        subagents: [CodexSubagentState],
        workspaceSummary: CodexWorkspaceSummaryContext? = nil,
        gitReviewSession: CodexGitReviewSession? = nil,
        chatTitle: String = "Codex",
        onEnvironmentHandoffCompletion: @escaping @MainActor @Sendable (CodexWorktreeHandoffCompletion) -> Void = { _ in },
        onSelectTab: @escaping (String) -> Void
    ) {
        self.sideChat = sideChat
        self.subagents = subagents
        self.workspaceSummary = workspaceSummary
        self.gitReviewSession = gitReviewSession
        self.chatTitle = chatTitle
        self.onEnvironmentHandoffCompletion = onEnvironmentHandoffCompletion
        self.onSelectTab = onSelectTab
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            if let workspaceSummary {
                SummarySection(title: "Workspace") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(workspaceSummary.workspaceLine)
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.textPrimary)
                            .lineLimit(2)
                        if let diffStatsLine = workspaceSummary.diffStatsLine {
                            Text(diffStatsLine)
                                .font(theme.fonts.caption)
                                .foregroundStyle(theme.colors.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                SummarySection(title: "Environment") {
                    CodexProjectEnvironmentPanel(
                        environment: CodexProjectEnvironmentState(
                            workspacePath: workspaceSummary.workspacePath,
                            branchName: workspaceSummary.gitBranch
                        ),
                        threadTitle: chatTitle,
                        onCompletion: onEnvironmentHandoffCompletion
                    )
                }
            }

            SummarySection(title: "Outputs") {
                Text("No artifacts yet")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }

            if let gitReviewSession {
                SummarySection(title: "Changes") {
                    SummaryRow(title: gitReviewSession.branchSummary.title, systemImage: "arrow.triangle.branch") {
                        onSelectTab(CodexAgentPanelTab.review(gitReviewSession).id)
                    }
                    Text(gitReviewSession.commitStats.summary)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                        .padding(.leading, 30)
                }
            }

            SummarySection(title: "Side chats") {
                if let sideChat {
                    SummaryRow(title: sideChat.title, systemImage: "rectangle.split.2x1") {
                        onSelectTab(sideChat.id)
                    }
                } else {
                    Text("No side chats yet")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .padding(.vertical, 4)
                }
            }

            let visibleAgents = subagents.filter(\.isVisibleInFloatingSummary)
            if !visibleAgents.isEmpty {
                SummarySection(title: "Subagents") {
                    ForEach(visibleAgents) { subagent in
                        SummaryRow(title: subagent.floatingSummaryTitle, systemImage: subagent.floatingSummarySystemImage) {
                            onSelectTab(subagent.id)
                        }
                    }
                }
            }

            SummarySection(title: "Sources") {
                Text("No sources yet")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: theme.spacing.summaryPanelWidth, alignment: .topLeading)
        .fixedSize(horizontal: true, vertical: false)
        .codexGlass(RoundedRectangle(cornerRadius: theme.radii.panel, style: .continuous))
    }
}

private struct SummarySection<Content: View>: View {
    @Environment(\.codexAgentTheme) private var theme

    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.down")
                    .font(theme.fonts.caption)
                Text(title)
                    .font(theme.fonts.caption.weight(.semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.colors.textTertiary)

            content
                .padding(.leading, 2)
        }
    }
}

private struct SummaryRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .frame(width: 16)
                Text(title)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(.clear, in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
    }
}

public struct CodexAgentSidePanel: View {
    @Environment(\.codexAgentTheme) private var theme

    private let tabs: [CodexAgentPanelTab]
    @Binding private var selectedTabID: String?
    @Binding private var sideChatDraft: String
    private let width: Binding<CGFloat>?
    private let isSideChatSending: Bool
    private let canSendSideChatMessage: Bool
    private let onSendSideChatMessage: () -> Void
    private let onInterruptSideChatMessage: () -> Void
    private let onClose: () -> Void
    @State private var resizeStartWidth: CGFloat?

    public init(
        tabs: [CodexAgentPanelTab],
        selectedTabID: Binding<String?>,
        sideChatDraft: Binding<String> = .constant(""),
        isSideChatSending: Bool = false,
        canSendSideChatMessage: Bool = false,
        onSendSideChatMessage: @escaping () -> Void = {},
        onInterruptSideChatMessage: @escaping () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        self.tabs = tabs
        self._selectedTabID = selectedTabID
        self._sideChatDraft = sideChatDraft
        self.width = nil
        self.isSideChatSending = isSideChatSending
        self.canSendSideChatMessage = canSendSideChatMessage
        self.onSendSideChatMessage = onSendSideChatMessage
        self.onInterruptSideChatMessage = onInterruptSideChatMessage
        self.onClose = onClose
    }

    public init(
        tabs: [CodexAgentPanelTab],
        selectedTabID: Binding<String?>,
        width: Binding<CGFloat>,
        sideChatDraft: Binding<String> = .constant(""),
        isSideChatSending: Bool = false,
        canSendSideChatMessage: Bool = false,
        onSendSideChatMessage: @escaping () -> Void = {},
        onInterruptSideChatMessage: @escaping () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        self.tabs = tabs
        self._selectedTabID = selectedTabID
        self._sideChatDraft = sideChatDraft
        self.width = width
        self.isSideChatSending = isSideChatSending
        self.canSendSideChatMessage = canSendSideChatMessage
        self.onSendSideChatMessage = onSendSideChatMessage
        self.onInterruptSideChatMessage = onInterruptSideChatMessage
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().overlay(theme.colors.border)
            if let tab = selectedTab {
                CodexAgentPanelContent(
                    tab: tab,
                    sideChatDraft: $sideChatDraft,
                    isSideChatSending: isSideChatSending,
                    canSendSideChatMessage: canSendSideChatMessage,
                    onSendSideChatMessage: onSendSideChatMessage,
                    onInterruptSideChatMessage: onInterruptSideChatMessage
                )
            } else {
                emptyPanel
            }
        }
        .frame(width: panelWidth)
        .frame(maxHeight: .infinity)
        .background(theme.colors.surface.opacity(theme.effects.surfaceOpacity))
        .overlay(alignment: .leading) {
            resizeHandle
        }
        .shadow(color: .black.opacity(theme.effects.glowOpacity), radius: 24, x: -8)
        .animation(nil, value: panelWidth)
        .onAppear(perform: ensureSelection)
        .onChange(of: tabs.map(\.id)) { _, _ in ensureSelection() }
    }

    private var panelWidth: CGFloat {
        clamped(width?.wrappedValue ?? theme.spacing.sidePanelWidth)
    }

    private var minPanelWidth: CGFloat { 300 }
    private var maxPanelWidth: CGFloat { 680 }

    private var resizeHandle: some View {
        ZStack {
            Rectangle()
                .fill(theme.colors.border)
                .frame(width: 1)

            if width != nil {
                Capsule()
                    .fill(theme.colors.textTertiary.opacity(0.34))
                    .frame(width: 3, height: 54)
                    .padding(.leading, 2)
            }
        }
        .frame(width: 14)
        .frame(maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(resizeGesture)
        .help(width == nil ? "Agent panel edge" : "Drag to resize agent panel")
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard let width else { return }
                let start = resizeStartWidth ?? panelWidth
                resizeStartWidth = start
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    width.wrappedValue = clamped(start - value.translation.width)
                }
            }
            .onEnded { _ in
                resizeStartWidth = nil
            }
    }

    private func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, minPanelWidth), maxPanelWidth)
    }

    private var selectedTab: CodexAgentPanelTab? {
        tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabs) { tab in
                        AgentPanelTabButton(
                            title: tab.title,
                            isSelected: tab.id == selectedTab?.id
                        ) {
                            selectedTabID = tab.id
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            Button(action: onClose) {
                Image(systemName: "sidebar.right")
                    .font(theme.fonts.label)
                    .foregroundStyle(theme.colors.textTertiary)
                    .frame(width: theme.spacing.iconLarge, height: theme.spacing.iconLarge)
            }
            .buttonStyle(.plain)
            .codexGlass(Circle(), interactive: true)
            .padding(.trailing, 8)
        }
        .frame(height: theme.spacing.toolbarHeight)
    }

    private var emptyPanel: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.split.2x1")
                .font(.title2)
                .foregroundStyle(theme.colors.textTertiary)
            Text("No agent tab selected")
                .font(theme.fonts.label)
                .foregroundStyle(theme.colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func ensureSelection() {
        guard !tabs.isEmpty else {
            selectedTabID = nil
            return
        }
        if selectedTabID == nil || !tabs.contains(where: { $0.id == selectedTabID }) {
            selectedTabID = tabs.first?.id
        }
    }
}

private struct AgentPanelTabButton: View {
    @Environment(\.codexAgentTheme) private var theme

    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.fonts.chat)
                .foregroundStyle(isSelected ? theme.colors.textPrimary : theme.colors.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    isSelected ? theme.colors.surfaceElevated.opacity(theme.effects.surfaceOpacity) : .clear,
                    in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct CodexAgentPanelContent: View {
    @Environment(\.codexAgentTheme) private var theme

    let tab: CodexAgentPanelTab
    @Binding var sideChatDraft: String
    let isSideChatSending: Bool
    let canSendSideChatMessage: Bool
    let onSendSideChatMessage: () -> Void
    let onInterruptSideChatMessage: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    parentChatPill

                    switch tab {
                    case .sideChat(let sideChat):
                        panelTranscript(
                            messages: sideChat.messages,
                            assistantName: "Codex",
                            empty: "Side chat is ready for a focused branch of the parent conversation."
                        )
                    case .subagent(let subagent):
                        subagentHeader(subagent)
                        panelTranscript(
                            messages: subagent.messages,
                            assistantName: subagent.name,
                            empty: "No transcript returned yet."
                        )
                    case .review(let session):
                        CodexGitReviewPanel(session: session)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 130)
            }
            .scrollContentBackground(.hidden)

            compactComposer(for: tab)
        }
    }

    private var parentChatPill: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.up.left")
                .font(theme.fonts.caption)
            Text("Parent chat")
                .font(theme.fonts.caption.weight(.semibold))
        }
        .foregroundStyle(theme.colors.textSecondary)
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(theme.colors.surfaceElevated.opacity(theme.effects.glassOpacity), in: Capsule())
        .overlay(Capsule().stroke(theme.colors.border, lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func subagentHeader(_ subagent: CodexSubagentState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(subagent.name)
                    .font(theme.fonts.body)
                    .foregroundStyle(theme.colors.textPrimary)
                SubagentStatusBadge(status: subagent.status)
            }
            if subagent.title != subagent.name {
                Text(subagent.title)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func panelTranscript(messages: [CodexChatMessage], assistantName: String, empty: String) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            if messages.isEmpty {
                emptyText(empty)
            } else {
                ForEach(messages) { message in
                    CodexMessageRow(message: message, assistantName: assistantName)
                }
            }
        }
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(theme.fonts.chat)
            .foregroundStyle(theme.colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 20)
    }

    @ViewBuilder
    private func compactComposer(for tab: CodexAgentPanelTab) -> some View {
        switch tab {
        case .sideChat:
            AgentPanelComposer(
                placeholder: "Ask side chat...",
                draft: $sideChatDraft,
                isEnabled: true,
                isSending: isSideChatSending,
                canSend: canSendSideChatMessage,
                onSend: onSendSideChatMessage,
                onInterrupt: onInterruptSideChatMessage
            )
        case .subagent:
            AgentPanelComposer(
                placeholder: "Ask this agent...",
                draft: .constant(""),
                isEnabled: false,
                isSending: false,
                canSend: false,
                onSend: {},
                onInterrupt: {}
            )
        case .review:
            EmptyView()
        }
    }
}

private struct AgentPanelComposer: View {
    @Environment(\.codexAgentTheme) private var theme

    let placeholder: String
    @Binding var draft: String
    let isEnabled: Bool
    let isSending: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onInterrupt: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.clear, theme.colors.surface],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .allowsHitTesting(false)

            HStack(spacing: 8) {
                composerToolButton(systemImage: "plus", help: "Add files to side chat")

                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(theme.fonts.chat)
                    .foregroundStyle(isEnabled ? theme.colors.textPrimary : theme.colors.textTertiary)
                    .lineLimit(1...4)
                    .focused($focused)
                    .disabled(!isEnabled)
                    .onSubmit(submit)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(minHeight: 44)
                    .background(theme.colors.surfaceElevated.opacity(theme.effects.textDimOpacity), in: RoundedRectangle(cornerRadius: theme.radii.composer, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.radii.composer, style: .continuous)
                            .stroke(theme.colors.border, lineWidth: 1)
                    )

                composerChip("Ask", help: "Side chat approval mode")
                composerChip("5.5", help: "Side chat model")
                composerToolButton(systemImage: "mic", help: "Dictate side chat")

                Button(action: isSending ? onInterrupt : submit) {
                    Image(systemName: isSending ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle((isSending || canSend) ? theme.colors.accent : theme.colors.textTertiary)
                }
                .buttonStyle(.plain)
                .disabled(!isSending && !canSend)
                .accessibilityLabel(isSending ? CodexComposerAccessibility.stopButtonLabel : CodexComposerAccessibility.sendButtonLabel(isEnabled: canSend))
                .help(isSending ? "Stop side chat" : "Send side chat message")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .background(theme.colors.surface)
        }
    }

    private func composerToolButton(systemImage: String, help: String) -> some View {
        Button {} label: {
            Image(systemName: systemImage)
                .font(theme.fonts.caption.weight(.semibold))
                .foregroundStyle(isEnabled ? theme.colors.textSecondary : theme.colors.textTertiary)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .disabled(true)
        .help(help)
        .accessibilityLabel(help)
    }

    private func composerChip(_ title: String, help: String) -> some View {
        Text(title)
            .font(theme.fonts.micro.weight(.semibold))
            .foregroundStyle(isEnabled ? theme.colors.textSecondary : theme.colors.textTertiary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(theme.colors.surfaceElevated.opacity(theme.effects.textDimOpacity), in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                    .stroke(theme.colors.border, lineWidth: 1)
            )
            .help(help)
            .accessibilityLabel(help)
    }

    private func submit() {
        guard canSend else { return }
        onSend()
    }
}

private struct SubagentStatusBadge: View {
    @Environment(\.codexAgentTheme) private var theme

    let status: CodexSubagentState.Status

    var body: some View {
        CodexStatusChip(color: color, label: status.rawValue, isStreaming: false)
    }

    private var color: Color {
        switch status {
        case .running: return theme.colors.running
        case .completed: return theme.colors.success
        case .closed: return theme.colors.textTertiary
        case .failed: return theme.colors.danger
        }
    }
}
