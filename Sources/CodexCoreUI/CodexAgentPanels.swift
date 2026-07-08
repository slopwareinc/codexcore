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
    private let terminalSessions: [CodexTerminalSession]
    private let browserSessions: [CodexBrowserSession]
    private let isSideChatSending: Bool
    private let canSendSideChatMessage: Bool
    private let onSendSideChatMessage: () -> Void
    private let onInterruptSideChatMessage: () -> Void
    private let onOpenTerminal: () -> Void
    private let onOpenBrowser: () -> Void
    private let onCloseTerminal: (String) -> Void
    private let onCloseBrowser: (String) -> Void
    private let onClose: () -> Void
    @State private var resizeStartWidth: CGFloat?
    @State private var liveResizeWidth: CGFloat?

    public init(
        tabs: [CodexAgentPanelTab],
        selectedTabID: Binding<String?>,
        terminalSessions: [CodexTerminalSession] = [],
        browserSessions: [CodexBrowserSession] = [],
        sideChatDraft: Binding<String> = .constant(""),
        isSideChatSending: Bool = false,
        canSendSideChatMessage: Bool = false,
        onSendSideChatMessage: @escaping () -> Void = {},
        onInterruptSideChatMessage: @escaping () -> Void = {},
        onOpenTerminal: @escaping () -> Void = {},
        onOpenBrowser: @escaping () -> Void = {},
        onCloseTerminal: @escaping (String) -> Void = { _ in },
        onCloseBrowser: @escaping (String) -> Void = { _ in },
        onClose: @escaping () -> Void
    ) {
        self.tabs = tabs
        self._selectedTabID = selectedTabID
        self._sideChatDraft = sideChatDraft
        self.width = nil
        self.terminalSessions = terminalSessions
        self.browserSessions = browserSessions
        self.isSideChatSending = isSideChatSending
        self.canSendSideChatMessage = canSendSideChatMessage
        self.onSendSideChatMessage = onSendSideChatMessage
        self.onInterruptSideChatMessage = onInterruptSideChatMessage
        self.onOpenTerminal = onOpenTerminal
        self.onOpenBrowser = onOpenBrowser
        self.onCloseTerminal = onCloseTerminal
        self.onCloseBrowser = onCloseBrowser
        self.onClose = onClose
    }

    public init(
        tabs: [CodexAgentPanelTab],
        selectedTabID: Binding<String?>,
        width: Binding<CGFloat>,
        terminalSessions: [CodexTerminalSession] = [],
        browserSessions: [CodexBrowserSession] = [],
        sideChatDraft: Binding<String> = .constant(""),
        isSideChatSending: Bool = false,
        canSendSideChatMessage: Bool = false,
        onSendSideChatMessage: @escaping () -> Void = {},
        onInterruptSideChatMessage: @escaping () -> Void = {},
        onOpenTerminal: @escaping () -> Void = {},
        onOpenBrowser: @escaping () -> Void = {},
        onCloseTerminal: @escaping (String) -> Void = { _ in },
        onCloseBrowser: @escaping (String) -> Void = { _ in },
        onClose: @escaping () -> Void
    ) {
        self.tabs = tabs
        self._selectedTabID = selectedTabID
        self._sideChatDraft = sideChatDraft
        self.width = width
        self.terminalSessions = terminalSessions
        self.browserSessions = browserSessions
        self.isSideChatSending = isSideChatSending
        self.canSendSideChatMessage = canSendSideChatMessage
        self.onSendSideChatMessage = onSendSideChatMessage
        self.onInterruptSideChatMessage = onInterruptSideChatMessage
        self.onOpenTerminal = onOpenTerminal
        self.onOpenBrowser = onOpenBrowser
        self.onCloseTerminal = onCloseTerminal
        self.onCloseBrowser = onCloseBrowser
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().overlay(theme.colors.border)
            panelContent
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

    @ViewBuilder
    private var panelContent: some View {
        ZStack {
            ForEach(terminalSessions) { session in
                CodexTerminalToolView(session: session)
                    .toolPanelVisibility(isSelected: session.id == selectedTabID)
                    .id(session.id)
            }

            ForEach(browserSessions) { session in
                CodexBrowserToolView(session: session)
                    .toolPanelVisibility(isSelected: session.id == selectedTabID)
                    .id(session.id)
            }

            if selectedTerminalSession == nil, selectedBrowserSession == nil {
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
                    toolLauncher
                }
            }
        }
    }

    private var panelWidth: CGFloat {
        liveResizeWidth ?? clamped(width?.wrappedValue ?? theme.spacing.sidePanelWidth)
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
        .help(width == nil ? "Tools panel edge" : "Drag to resize tools panel")
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                guard width != nil else { return }
                let start = resizeStartWidth ?? panelWidth
                resizeStartWidth = start
                let nextWidth = clamped(start - value.translation.width)
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    liveResizeWidth = nextWidth
                }
            }
            .onEnded { _ in
                if let liveResizeWidth {
                    width?.wrappedValue = liveResizeWidth
                }
                resizeStartWidth = nil
                liveResizeWidth = nil
            }
    }

    private func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, minPanelWidth), maxPanelWidth)
    }

    private var selectedTab: CodexAgentPanelTab? {
        guard selectedTerminalSession == nil, selectedBrowserSession == nil else { return nil }
        return tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    private var selectedTerminalSession: CodexTerminalSession? {
        terminalSessions.first { $0.id == selectedTabID }
    }

    private var selectedBrowserSession: CodexBrowserSession? {
        browserSessions.first { $0.id == selectedTabID }
    }

    private var hasOpenTabs: Bool {
        !terminalSessions.isEmpty || !browserSessions.isEmpty || !tabs.isEmpty
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(terminalSessions) { session in
                        AgentPanelTabButton(
                            title: session.title,
                            systemImage: "terminal",
                            isSelected: session.id == selectedTabID,
                            closeAction: { onCloseTerminal(session.id) }
                        ) {
                            selectedTabID = session.id
                        }
                    }

                    ForEach(browserSessions) { session in
                        BrowserPanelTabButton(
                            session: session,
                            isSelected: session.id == selectedTabID,
                            closeAction: { onCloseBrowser(session.id) }
                        ) {
                            selectedTabID = session.id
                        }
                    }

                    ForEach(tabs) { tab in
                        AgentPanelTabButton(
                            title: tab.title,
                            systemImage: tab.systemImage,
                            isSelected: tab.id == selectedTab?.id,
                            closeAction: nil
                        ) {
                            selectedTabID = tab.id
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            Menu {
                ForEach(CodexWorkspaceToolCatalog.launcherOptions) { option in
                    Button(option.title) {
                        openTool(option.id)
                    }
                    .disabled(!option.isEnabled)
                }
            } label: {
                Image(systemName: "plus")
                    .font(theme.fonts.label)
                    .foregroundStyle(theme.colors.textSecondary)
                    .frame(width: theme.spacing.iconLarge, height: theme.spacing.iconLarge)
            }
            .menuStyle(.borderlessButton)
            .frame(width: theme.spacing.iconLarge, height: theme.spacing.iconLarge)
            .help("Open tool")
            .accessibilityLabel("Open tool")

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

    private var toolLauncher: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Open a tool")
                    .font(theme.fonts.body.weight(.semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Text("Run workspace tools beside the current chat.")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
            }

            VStack(spacing: 8) {
                ForEach(CodexWorkspaceToolCatalog.launcherOptions) { option in
                    WorkspaceToolLauncherRow(option: option) {
                        openTool(option.id)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func ensureSelection() {
        guard hasOpenTabs else {
            selectedTabID = nil
            return
        }
        if let selectedTabID,
           terminalSessions.contains(where: { $0.id == selectedTabID })
            || browserSessions.contains(where: { $0.id == selectedTabID })
            || tabs.contains(where: { $0.id == selectedTabID }) {
            return
        }
        selectedTabID = terminalSessions.first?.id ?? browserSessions.first?.id ?? tabs.first?.id
    }

    private func openTool(_ id: String) {
        switch id {
        case CodexWorkspaceToolCatalog.terminalID:
            onOpenTerminal()
        case CodexWorkspaceToolCatalog.browserID:
            onOpenBrowser()
        default:
            break
        }
    }
}

private struct AgentPanelTabButton: View {
    @Environment(\.codexAgentTheme) private var theme

    let title: String
    let systemImage: String
    let isSelected: Bool
    let closeAction: (() -> Void)?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(theme.fonts.caption)
                    Text(title)
                        .font(theme.fonts.chat)
                        .lineLimit(1)
                }
                .foregroundStyle(isSelected ? theme.colors.textPrimary : theme.colors.textSecondary)
                .padding(.leading, 9)
                .padding(.trailing, closeAction == nil ? 9 : 2)
                .frame(height: 28)
            }
            .buttonStyle(.plain)

            if let closeAction {
                Button(action: closeAction) {
                    Image(systemName: "xmark")
                        .font(theme.fonts.micro.weight(.bold))
                        .foregroundStyle(theme.colors.textTertiary)
                        .frame(width: 20, height: 24)
                }
                .buttonStyle(.plain)
                .help("Close \(title)")
                .accessibilityLabel("Close \(title)")
                .padding(.trailing, 4)
            }
        }
        .background(
            isSelected ? theme.colors.surfaceElevated.opacity(theme.effects.surfaceOpacity) : .clear,
            in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
        )
    }
}

private struct BrowserPanelTabButton: View {
    @ObservedObject var session: CodexBrowserSession

    let isSelected: Bool
    let closeAction: () -> Void
    let action: () -> Void

    var body: some View {
        AgentPanelTabButton(
            title: session.title,
            systemImage: "globe",
            isSelected: isSelected,
            closeAction: closeAction,
            action: action
        )
    }
}

private extension View {
    func toolPanelVisibility(isSelected: Bool) -> some View {
        self
            .opacity(isSelected ? 1 : 0)
            .allowsHitTesting(isSelected)
            .accessibilityHidden(!isSelected)
    }
}

private struct WorkspaceToolLauncherRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let option: CodexWorkspaceToolOption
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: option.systemImage)
                    .font(theme.fonts.label)
                    .foregroundStyle(option.isEnabled ? theme.colors.textSecondary : theme.colors.textTertiary.opacity(0.7))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(option.title)
                        .font(theme.fonts.label)
                        .foregroundStyle(option.isEnabled ? theme.colors.textPrimary : theme.colors.textTertiary)
                    Text(option.detail)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                if option.isEnabled {
                    Image(systemName: "chevron.right")
                        .font(theme.fonts.caption.weight(.semibold))
                        .foregroundStyle(theme.colors.textTertiary)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.colors.surfaceElevated.opacity(option.isEnabled ? theme.effects.textDimOpacity : 0.28), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                    .stroke(theme.colors.border.opacity(option.isEnabled ? 1 : 0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!option.isEnabled)
        .accessibilityLabel(option.isEnabled ? "Open \(option.title)" : "\(option.title). \(option.detail)")
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
        ZStack(alignment: .bottom) {
            switch tab {
            case .sideChat(let sideChat):
                transcriptPanel(
                    messages: sideChat.messages,
                    transcriptID: sideChat.id,
                    empty: "Side chat is ready for a focused branch of the parent conversation."
                )
            case .subagent(let subagent):
                transcriptPanel(
                    messages: subagent.messages,
                    transcriptID: subagent.id,
                    empty: "No transcript returned yet."
                ) {
                    subagentHeader(subagent)
                }
            case .review(let session):
                reviewPanel(session)
            }

            compactComposer(for: tab)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
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

    private func transcriptPanel(
        messages: [CodexChatMessage],
        transcriptID: String,
        empty: String
    ) -> some View {
        transcriptPanel(
            messages: messages,
            transcriptID: transcriptID,
            empty: empty
        ) {
            EmptyView()
        }
    }

    private func transcriptPanel<Header: View>(
        messages: [CodexChatMessage],
        transcriptID: String,
        empty: String,
        @ViewBuilder header: () -> Header
    ) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                parentChatPill
                header()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            CodexTranscriptView(
                messages: messages,
                transcriptID: "agent-panel-\(transcriptID)",
                bottomContentMargin: 96
            ) {
                emptyText(empty)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reviewPanel(_ session: CodexGitReviewSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                parentChatPill
                CodexGitReviewPanel(session: session)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 130)
        }
        .scrollContentBackground(.hidden)
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
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(minHeight: 38)
                .background(theme.colors.surfaceElevated.opacity(theme.effects.textDimOpacity), in: RoundedRectangle(cornerRadius: theme.radii.composer, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radii.composer, style: .continuous)
                        .stroke(theme.colors.border.opacity(0.85), lineWidth: 1)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .codexGlass(RoundedRectangle(cornerRadius: theme.radii.composer, style: .continuous), interactive: true)
        .shadow(color: .black.opacity(theme.effects.glowOpacity), radius: 18, x: 0, y: 8)
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
