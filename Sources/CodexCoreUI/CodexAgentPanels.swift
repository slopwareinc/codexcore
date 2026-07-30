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
        VStack(alignment: .leading, spacing: 18) {
            if let workspaceSummary {
                SummarySection(title: "Environment", showsAddButton: true) {
                    if let gitReviewSession {
                        SummaryRow(
                            title: "Changes",
                            systemImage: "plus.forwardslash.minus",
                            trailing: AnyView(
                                SummaryDiffStats(
                                    added: gitReviewSession.commitStats.addedLines,
                                    removed: gitReviewSession.commitStats.removedLines
                                )
                            )
                        ) {
                            onSelectTab(CodexAgentPanelTab.review(gitReviewSession).id)
                        }
                    }

                    SummaryRow(
                        title: workspaceSummary.environmentModeTitle,
                        systemImage: workspaceSummary.environmentModeTitle == "Worktree"
                            ? "square.stack.3d.up"
                            : "laptopcomputer",
                        trailingSystemImage: "chevron.down"
                    )

                    SummaryRow(
                        title: workspaceSummary.gitBranch?.nilIfBlank ?? "No branch",
                        systemImage: "arrow.triangle.branch",
                        trailingSystemImage: "chevron.down"
                    )

                    if workspaceSummary.gitBranch?.nilIfBlank != nil {
                        if let gitReviewSession {
                            SummaryRow(title: "Commit or push", systemImage: "icloud.and.arrow.up") {
                                onSelectTab(CodexAgentPanelTab.review(gitReviewSession).id)
                            }
                            SummaryRow(title: "Create pull request", systemImage: "arrow.triangle.pull") {
                                onSelectTab(CodexAgentPanelTab.review(gitReviewSession).id)
                            }
                        } else {
                            SummaryRow(title: "Commit or push", systemImage: "icloud.and.arrow.up")
                            SummaryRow(title: "Create pull request", systemImage: "arrow.triangle.pull")
                        }
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "folder")
                            .frame(width: 22)
                        Text(workspaceSummary.workspaceLine)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .padding(.top, 2)
                }
            }

            if let sideChat {
                SummaryDivider()
                SummarySection(title: "Side chats") {
                    SummaryRow(title: sideChat.title, systemImage: "rectangle.split.2x1") {
                        onSelectTab(sideChat.id)
                    }
                }
            }

            let visibleAgents = subagents.filter(\.isVisibleInFloatingSummary)
            if !visibleAgents.isEmpty {
                SummaryDivider()
                SummarySection(title: "Subagents") {
                    ForEach(visibleAgents) { subagent in
                        SummaryRow(title: subagent.floatingSummaryTitle, systemImage: subagent.floatingSummarySystemImage) {
                            onSelectTab(subagent.id)
                        }
                    }
                }
            }

            SummaryDivider()
            SummarySection(title: "Outputs", showsAddButton: true) {
                SummaryEmptyRow(title: "No artifacts yet")
            }

            SummaryDivider()
            SummarySection(title: "Sources", showsAddButton: true) {
                if let sourceFiles = workspaceSummary?.sourceFiles, !sourceFiles.isEmpty {
                    ForEach(sourceFiles.suffix(3)) { source in
                        SummarySourceRow(source: source)
                    }
                    if sourceFiles.count > 3 {
                        SummaryRow(
                            title: "View all",
                            systemImage: "point.3.connected.trianglepath.dotted"
                        )
                    }
                } else {
                    SummaryEmptyRow(title: "No sources yet")
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .frame(width: theme.spacing.summaryPanelWidth, alignment: .topLeading)
        .fixedSize(horizontal: true, vertical: false)
        .codexGlass(RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous), role: .panel)
    }
}

private struct SummarySection<Content: View>: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var isExpanded = true
    @State private var isHovered = false

    let title: String
    let showsAddButton: Bool
    let content: Content

    init(
        title: String,
        showsAddButton: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.showsAddButton = showsAddButton
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(theme.fonts.micro)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Text(title)
                            .font(theme.fonts.body)
                    }
                    .foregroundStyle(theme.colors.textTertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                if showsAddButton {
                    Image(systemName: "plus")
                        .font(theme.fonts.actionIcon)
                        .foregroundStyle(theme.colors.textTertiary)
                        .frame(width: 24, height: 24)
                        .opacity(isHovered ? 1 : 0.72)
                        .help("\(title) actions are not available yet")
                }
            }
            .frame(height: 24)
            .onHover { isHovered = $0 }

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    content
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct SummaryRow: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var isHovered = false

    let title: String
    let systemImage: String
    let trailing: AnyView?
    let trailingSystemImage: String?
    let action: (() -> Void)?

    init(
        title: String,
        systemImage: String,
        trailing: AnyView? = nil,
        trailingSystemImage: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing
        self.trailingSystemImage = trailingSystemImage
        self.action = action
    }

    init(
        title: String,
        systemImage: String,
        trailing: AnyView? = nil,
        trailingSystemImage: String? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            trailing: trailing,
            trailingSystemImage: trailingSystemImage,
            action: Optional(action)
        )
    }

    var body: some View {
        Group {
            if let action {
                Button(action: action) { rowContent }
                    .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .background(
            isHovered ? theme.colors.surfaceElevated.opacity(0.42) : .clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .onHover { isHovered = $0 }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(theme.fonts.actionIcon)
                .foregroundStyle(theme.colors.textSecondary)
                .frame(width: 24, height: 24)
            Text(title)
                .font(theme.fonts.body)
                .foregroundStyle(theme.colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let trailing {
                trailing
            } else if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(theme.fonts.chipLabel)
                    .foregroundStyle(theme.colors.textTertiary)
            }
        }
        .frame(height: 36)
        .padding(.horizontal, 4)
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct SummaryDiffStats: View {
    @Environment(\.codexAgentTheme) private var theme

    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 5) {
            Text("+\(added)")
                .foregroundStyle(theme.colors.success)
            Text("-\(removed)")
                .foregroundStyle(theme.colors.danger)
        }
        .font(theme.fonts.code)
    }
}

private struct SummaryEmptyRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let title: String

    var body: some View {
        Text(title)
            .font(theme.fonts.caption)
            .foregroundStyle(theme.colors.textTertiary)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 38)
    }
}

private struct SummarySourceRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let source: CodexReferencedFile

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(theme.colors.border.opacity(0.65), lineWidth: 1)
                }
            Text(source.displayName)
                .font(theme.fonts.body)
                .foregroundStyle(theme.colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(height: 36)
        .padding(.horizontal, 4)
        .help(source.path)
    }

    @ViewBuilder
    private var thumbnail: some View {
        CodexReferencedFilePreview(file: source)
    }
}

private struct SummaryDivider: View {
    @Environment(\.codexAgentTheme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.colors.border.opacity(0.46))
            .frame(height: 1)
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
    private let filesSessions: [CodexFilesSession]
    private let filePreviewSessions: [CodexFilePreviewSession]
    private let mountedTerminalSessions: [CodexTerminalSession]
    private let mountedBrowserSessions: [CodexBrowserSession]
    private let mountedFilesSessions: [CodexFilesSession]
    private let mountedFilePreviewSessions: [CodexFilePreviewSession]
    private let modelOptions: [CodexModelSelection]
    private let isSideChatSending: Bool
    private let canSendSideChatMessage: Bool
    private let onSendSideChatMessage: () -> Void
    private let onInterruptSideChatMessage: () -> Void
    private let onOpenTerminal: () -> Void
    private let onOpenBrowser: () -> Void
    private let onOpenFiles: () -> Void
    private let onOpenFilePreview: (URL) -> Void
    private let onCloseTerminal: (String) -> Void
    private let onCloseBrowser: (String) -> Void
    private let onCloseFiles: (String) -> Void
    private let onCloseFilePreview: (String) -> Void
    private let onCloseSubagent: (String) -> Void
    private let onSelectSubagentTranscript: (String?) -> Void
    private let showsCloseButton: Bool
    private let onClose: () -> Void
    @State private var resizeStartWidth: CGFloat?
    @State private var liveResizeWidth: CGFloat?

    public init(
        tabs: [CodexAgentPanelTab],
        selectedTabID: Binding<String?>,
        terminalSessions: [CodexTerminalSession] = [],
        browserSessions: [CodexBrowserSession] = [],
        filesSessions: [CodexFilesSession] = [],
        filePreviewSessions: [CodexFilePreviewSession] = [],
        mountedTerminalSessions: [CodexTerminalSession] = [],
        mountedBrowserSessions: [CodexBrowserSession] = [],
        mountedFilesSessions: [CodexFilesSession] = [],
        mountedFilePreviewSessions: [CodexFilePreviewSession] = [],
        modelOptions: [CodexModelSelection] = CodexModelSelection.defaultOptions,
        sideChatDraft: Binding<String> = .constant(""),
        isSideChatSending: Bool = false,
        canSendSideChatMessage: Bool = false,
        onSendSideChatMessage: @escaping () -> Void = {},
        onInterruptSideChatMessage: @escaping () -> Void = {},
        onOpenTerminal: @escaping () -> Void = {},
        onOpenBrowser: @escaping () -> Void = {},
        onOpenFiles: @escaping () -> Void = {},
        onOpenFilePreview: @escaping (URL) -> Void = { _ in },
        onCloseTerminal: @escaping (String) -> Void = { _ in },
        onCloseBrowser: @escaping (String) -> Void = { _ in },
        onCloseFiles: @escaping (String) -> Void = { _ in },
        onCloseFilePreview: @escaping (String) -> Void = { _ in },
        onCloseSubagent: @escaping (String) -> Void = { _ in },
        onSelectSubagentTranscript: @escaping (String?) -> Void = { _ in },
        showsCloseButton: Bool = true,
        onClose: @escaping () -> Void
    ) {
        self.tabs = tabs
        self._selectedTabID = selectedTabID
        self._sideChatDraft = sideChatDraft
        self.width = nil
        self.terminalSessions = terminalSessions
        self.browserSessions = browserSessions
        self.filesSessions = filesSessions
        self.filePreviewSessions = filePreviewSessions
        self.mountedTerminalSessions = mountedTerminalSessions
        self.mountedBrowserSessions = mountedBrowserSessions
        self.mountedFilesSessions = mountedFilesSessions
        self.mountedFilePreviewSessions = mountedFilePreviewSessions
        self.modelOptions = modelOptions
        self.isSideChatSending = isSideChatSending
        self.canSendSideChatMessage = canSendSideChatMessage
        self.onSendSideChatMessage = onSendSideChatMessage
        self.onInterruptSideChatMessage = onInterruptSideChatMessage
        self.onOpenTerminal = onOpenTerminal
        self.onOpenBrowser = onOpenBrowser
        self.onOpenFiles = onOpenFiles
        self.onOpenFilePreview = onOpenFilePreview
        self.onCloseTerminal = onCloseTerminal
        self.onCloseBrowser = onCloseBrowser
        self.onCloseFiles = onCloseFiles
        self.onCloseFilePreview = onCloseFilePreview
        self.onCloseSubagent = onCloseSubagent
        self.onSelectSubagentTranscript = onSelectSubagentTranscript
        self.showsCloseButton = showsCloseButton
        self.onClose = onClose
    }

    public init(
        tabs: [CodexAgentPanelTab],
        selectedTabID: Binding<String?>,
        width: Binding<CGFloat>,
        terminalSessions: [CodexTerminalSession] = [],
        browserSessions: [CodexBrowserSession] = [],
        filesSessions: [CodexFilesSession] = [],
        filePreviewSessions: [CodexFilePreviewSession] = [],
        mountedTerminalSessions: [CodexTerminalSession] = [],
        mountedBrowserSessions: [CodexBrowserSession] = [],
        mountedFilesSessions: [CodexFilesSession] = [],
        mountedFilePreviewSessions: [CodexFilePreviewSession] = [],
        modelOptions: [CodexModelSelection] = CodexModelSelection.defaultOptions,
        sideChatDraft: Binding<String> = .constant(""),
        isSideChatSending: Bool = false,
        canSendSideChatMessage: Bool = false,
        onSendSideChatMessage: @escaping () -> Void = {},
        onInterruptSideChatMessage: @escaping () -> Void = {},
        onOpenTerminal: @escaping () -> Void = {},
        onOpenBrowser: @escaping () -> Void = {},
        onOpenFiles: @escaping () -> Void = {},
        onOpenFilePreview: @escaping (URL) -> Void = { _ in },
        onCloseTerminal: @escaping (String) -> Void = { _ in },
        onCloseBrowser: @escaping (String) -> Void = { _ in },
        onCloseFiles: @escaping (String) -> Void = { _ in },
        onCloseFilePreview: @escaping (String) -> Void = { _ in },
        onCloseSubagent: @escaping (String) -> Void = { _ in },
        onSelectSubagentTranscript: @escaping (String?) -> Void = { _ in },
        showsCloseButton: Bool = true,
        onClose: @escaping () -> Void
    ) {
        self.tabs = tabs
        self._selectedTabID = selectedTabID
        self._sideChatDraft = sideChatDraft
        self.width = width
        self.terminalSessions = terminalSessions
        self.browserSessions = browserSessions
        self.filesSessions = filesSessions
        self.filePreviewSessions = filePreviewSessions
        self.mountedTerminalSessions = mountedTerminalSessions
        self.mountedBrowserSessions = mountedBrowserSessions
        self.mountedFilesSessions = mountedFilesSessions
        self.mountedFilePreviewSessions = mountedFilePreviewSessions
        self.modelOptions = modelOptions
        self.isSideChatSending = isSideChatSending
        self.canSendSideChatMessage = canSendSideChatMessage
        self.onSendSideChatMessage = onSendSideChatMessage
        self.onInterruptSideChatMessage = onInterruptSideChatMessage
        self.onOpenTerminal = onOpenTerminal
        self.onOpenBrowser = onOpenBrowser
        self.onOpenFiles = onOpenFiles
        self.onOpenFilePreview = onOpenFilePreview
        self.onCloseTerminal = onCloseTerminal
        self.onCloseBrowser = onCloseBrowser
        self.onCloseFiles = onCloseFiles
        self.onCloseFilePreview = onCloseFilePreview
        self.onCloseSubagent = onCloseSubagent
        self.onSelectSubagentTranscript = onSelectSubagentTranscript
        self.showsCloseButton = showsCloseButton
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
        .animation(nil, value: panelWidth)
        .onAppear {
            ensureSelection()
            publishSelectedSubagent()
        }
        .onChange(of: tabs.map(\.id)) { _, _ in
            ensureSelection()
            publishSelectedSubagent()
        }
        .onChange(of: selectedTabID) { _, _ in publishSelectedSubagent() }
        .onDisappear { onSelectSubagentTranscript(nil) }
    }

    // The deck keeps every recent chat's tool surfaces mounted at once; only the
    // session matching the active selection is shown. Falls back to the active
    // chat's own sessions when no mounted union is supplied.
    private var deckTerminalSessions: [CodexTerminalSession] {
        mountedTerminalSessions.isEmpty ? terminalSessions : mountedTerminalSessions
    }

    private var deckBrowserSessions: [CodexBrowserSession] {
        mountedBrowserSessions.isEmpty ? browserSessions : mountedBrowserSessions
    }

    private var deckFilesSessions: [CodexFilesSession] {
        mountedFilesSessions.isEmpty ? filesSessions : mountedFilesSessions
    }

    private var deckFilePreviewSessions: [CodexFilePreviewSession] {
        mountedFilePreviewSessions.isEmpty ? filePreviewSessions : mountedFilePreviewSessions
    }

    @ViewBuilder
    private var panelContent: some View {
        ZStack {
            ForEach(deckTerminalSessions) { session in
                CodexTerminalToolView(session: session, isActive: session.id == selectedTabID)
                    .toolPanelVisibility(isSelected: session.id == selectedTabID)
                    .id(session.id)
            }

            ForEach(deckBrowserSessions) { session in
                CodexBrowserToolView(session: session)
                    .toolPanelVisibility(isSelected: session.id == selectedTabID)
                    .id(session.id)
            }

            ForEach(deckFilesSessions) { session in
                CodexFilesToolView(session: session, onOpenFile: onOpenFilePreview)
                    .toolPanelVisibility(isSelected: session.id == selectedTabID)
                    .id(session.id)
            }

            ForEach(deckFilePreviewSessions) { session in
                CodexFilePreviewView(url: session.fileURL)
                    .toolPanelVisibility(isSelected: session.id == selectedTabID)
                    .id(session.id)
            }

            if selectedTerminalSession == nil, selectedBrowserSession == nil,
               selectedFilesSession == nil, selectedFilePreviewSession == nil {
                if let tab = selectedTab {
                    CodexAgentPanelContent(
                        tab: tab,
                        sideChatDraft: $sideChatDraft,
                        isSideChatSending: isSideChatSending,
                        canSendSideChatMessage: canSendSideChatMessage,
                        onSendSideChatMessage: onSendSideChatMessage,
                        onInterruptSideChatMessage: onInterruptSideChatMessage,
                        modelOptions: modelOptions
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
        guard selectedTerminalSession == nil, selectedBrowserSession == nil,
              selectedFilesSession == nil, selectedFilePreviewSession == nil else { return nil }
        return tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    private func publishSelectedSubagent() {
        guard case .subagent(let subagent)? = selectedTab else {
            onSelectSubagentTranscript(nil)
            return
        }
        onSelectSubagentTranscript(subagent.id)
    }

    private var selectedTerminalSession: CodexTerminalSession? {
        terminalSessions.first { $0.id == selectedTabID }
    }

    private var selectedBrowserSession: CodexBrowserSession? {
        browserSessions.first { $0.id == selectedTabID }
    }

    private var selectedFilesSession: CodexFilesSession? {
        filesSessions.first { $0.id == selectedTabID }
    }

    private var selectedFilePreviewSession: CodexFilePreviewSession? {
        filePreviewSessions.first { $0.id == selectedTabID }
    }

    private var hasOpenTabs: Bool {
        !terminalSessions.isEmpty || !browserSessions.isEmpty || !filesSessions.isEmpty
            || !filePreviewSessions.isEmpty || !tabs.isEmpty
    }

    private var orderedTabIDs: [String] {
        terminalSessions.map(\.id)
            + browserSessions.map(\.id)
            + filesSessions.map(\.id)
            + filePreviewSessions.map(\.id)
            + tabs.map(\.id)
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            GeometryReader { geometry in
                let tabWidth = CodexAgentPanelTabStripLayout.tabWidth(
                    availableWidth: geometry.size.width,
                    tabCount: orderedTabIDs.count
                )

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(terminalSessions) { session in
                            AgentPanelTabButton(
                                title: session.title,
                                systemImage: "terminal",
                                isSelected: session.id == selectedTabID,
                                width: tabWidth,
                                showsLeadingDivider: showsLeadingDivider(for: session.id),
                                closeAction: { onCloseTerminal(session.id) }
                            ) {
                                selectedTabID = session.id
                            }
                        }

                        ForEach(browserSessions) { session in
                            BrowserPanelTabButton(
                                session: session,
                                isSelected: session.id == selectedTabID,
                                width: tabWidth,
                                showsLeadingDivider: showsLeadingDivider(for: session.id),
                                closeAction: { onCloseBrowser(session.id) }
                            ) {
                                selectedTabID = session.id
                            }
                        }

                        ForEach(filesSessions) { session in
                            AgentPanelTabButton(
                                title: session.title,
                                systemImage: "folder",
                                isSelected: session.id == selectedTabID,
                                width: tabWidth,
                                showsLeadingDivider: showsLeadingDivider(for: session.id),
                                closeAction: { onCloseFiles(session.id) }
                            ) {
                                selectedTabID = session.id
                            }
                        }

                        ForEach(filePreviewSessions) { session in
                            AgentPanelTabButton(
                                title: session.title,
                                systemImage: "doc.text",
                                isSelected: session.id == selectedTabID,
                                width: tabWidth,
                                showsLeadingDivider: showsLeadingDivider(for: session.id),
                                closeAction: { onCloseFilePreview(session.id) }
                            ) {
                                selectedTabID = session.id
                            }
                        }

                        ForEach(tabs) { tab in
                            AgentPanelTabButton(
                                title: tab.title,
                                systemImage: tab.systemImage,
                                isSelected: tab.id == selectedTab?.id,
                                width: tabWidth,
                                showsLeadingDivider: showsLeadingDivider(for: tab.id),
                                closeAction: tab.isSubagent ? { onCloseSubagent(tab.id) } : nil
                            ) {
                                selectedTabID = tab.id
                            }
                        }
                    }
                }
                .background(
                    theme.colors.surfaceElevated.opacity(theme.effects.surfaceOpacity * 0.42),
                    in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                )
            }
            .frame(height: 34)
            .padding(.leading, 8)

            HStack(spacing: 8) {
                Menu {
                    ForEach(CodexWorkspaceToolCatalog.launcherOptions) { option in
                        Button {
                            openTool(option.id)
                        } label: {
                            Label(option.title, systemImage: option.systemImage)
                        }
                        .disabled(!option.isEnabled)
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(theme.fonts.label)
                        .foregroundStyle(theme.colors.textSecondary)
                        .frame(width: theme.spacing.iconLarge, height: theme.spacing.iconLarge)
                        .contentShape(Circle())
                }
                // The launcher is deliberately plain chrome. Making this a lone
                // interactive glass surface causes the compositor to flex its
                // bubble whenever the pointer crosses it.
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .buttonStyle(.plain)
                .help("Open tool")
                .accessibilityLabel("Open tool")

                if showsCloseButton {
                    Button(action: onClose) {
                        Image(systemName: "sidebar.right")
                            .font(theme.fonts.label)
                            .foregroundStyle(theme.colors.textTertiary)
                            .frame(width: theme.spacing.iconLarge, height: theme.spacing.iconLarge)
                    }
                    .buttonStyle(.plain)
                    .codexGlass(Circle(), role: .control)
                    .help("Close side panel")
                    .accessibilityLabel("Close side panel")
                }
            }
            .padding(.trailing, 8)
        }
        .frame(height: theme.spacing.toolbarHeight)
    }

    private func showsLeadingDivider(for tabID: String) -> Bool {
        guard let index = orderedTabIDs.firstIndex(of: tabID), index > 0 else {
            return false
        }
        return CodexAgentPanelTabStripLayout.showsLeadingDivider(
            tabID: tabID,
            precedingTabID: orderedTabIDs[index - 1],
            selectedTabID: selectedTabID
        )
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
            || filesSessions.contains(where: { $0.id == selectedTabID })
            || filePreviewSessions.contains(where: { $0.id == selectedTabID })
            || tabs.contains(where: { $0.id == selectedTabID }) {
            return
        }
        selectedTabID = terminalSessions.first?.id
            ?? browserSessions.first?.id
            ?? filesSessions.first?.id
            ?? filePreviewSessions.first?.id
            ?? tabs.first?.id
    }

    private func openTool(_ id: String) {
        switch id {
        case CodexWorkspaceToolCatalog.terminalID:
            onOpenTerminal()
        case CodexWorkspaceToolCatalog.browserID:
            onOpenBrowser()
        case CodexWorkspaceToolCatalog.filesID:
            onOpenFiles()
        default:
            break
        }
    }
}

struct CodexAgentPanelTabStripLayout {
    static let minimumTabWidth: CGFloat = 112

    static func tabWidth(availableWidth: CGFloat, tabCount: Int) -> CGFloat {
        guard tabCount > 0 else { return availableWidth }
        return max(minimumTabWidth, floor(availableWidth / CGFloat(tabCount)))
    }

    static func showsLeadingDivider(
        tabID: String,
        precedingTabID: String?,
        selectedTabID: String?
    ) -> Bool {
        precedingTabID != nil
            && tabID != selectedTabID
            && precedingTabID != selectedTabID
    }
}

private struct AgentPanelTabButton: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var isHovered = false

    let title: String
    let systemImage: String
    let isSelected: Bool
    let width: CGFloat
    let showsLeadingDivider: Bool
    let closeAction: (() -> Void)?
    let action: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(theme.fonts.caption)
                    Text(title)
                        .font(theme.fonts.chat)
                        .lineLimit(1)
                }
                .foregroundStyle(isSelected ? theme.colors.textPrimary : theme.colors.textSecondary)
                .padding(.horizontal, closeAction == nil ? 10 : 30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .padding(.trailing, 5)
            }
        }
        .frame(width: width, height: 30)
        .background(
            tabBackground,
            in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                    .stroke(theme.colors.border.opacity(0.72), lineWidth: 1)
            }
        }
        .overlay(alignment: .leading) {
            if showsLeadingDivider {
                Rectangle()
                    .fill(theme.colors.border.opacity(0.58))
                    .frame(width: 1, height: 16)
            }
        }
        .padding(.vertical, 2)
        .onHover { isHovered = $0 }
    }

    private var tabBackground: Color {
        if isSelected {
            return theme.colors.surfaceElevated.opacity(theme.effects.surfaceOpacity)
        }
        if isHovered {
            return theme.colors.surfaceElevated.opacity(theme.effects.surfaceOpacity * 0.5)
        }
        return .clear
    }
}

private struct BrowserPanelTabButton: View {
    @ObservedObject var session: CodexBrowserSession

    let isSelected: Bool
    let width: CGFloat
    let showsLeadingDivider: Bool
    let closeAction: () -> Void
    let action: () -> Void

    var body: some View {
        AgentPanelTabButton(
            title: session.title,
            systemImage: "globe",
            isSelected: isSelected,
            width: width,
            showsLeadingDivider: showsLeadingDivider,
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
    let modelOptions: [CodexModelSelection]
    @State private var agentDraft = ""
    @State private var agentApproval = CodexApprovalSelection.askForApproval
    @State private var agentModel = CodexModelSelection.appServerDefault
    @State private var agentReasoning = CodexReasoningSelection.medium

    var body: some View {
        ZStack(alignment: .bottom) {
            switch tab {
            case .sideChat(let sideChat):
                transcriptPanel(
                    transcript: sideChat.transcript,
                    transcriptID: sideChat.id,
                    empty: "Side chat is ready for a focused branch of the parent conversation."
                )
            case .subagent(let subagent):
                transcriptPanel(
                    transcript: subagent.transcript,
                    transcriptID: subagent.id,
                    empty: subagent.transcriptAvailability == .exceedsDisplayLimit
                        ? "This transcript exceeds the in-memory display limit."
                        : "No transcript returned yet."
                ) {
                    subagentHeader(subagent)
                }
            case .review(let session):
                reviewPanel(session)
            }

            compactComposer(for: tab)
                .padding(.horizontal, 20)
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
        transcript: CodexTranscriptV2,
        transcriptID: String,
        empty: String
    ) -> some View {
        transcriptPanel(
            transcript: transcript,
            transcriptID: transcriptID,
            empty: empty
        ) {
            EmptyView()
        }
    }

    private func transcriptPanel<Header: View>(
        transcript: CodexTranscriptV2,
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

            CodexTranscriptViewV2(
                transcript: transcript
            ) {
                emptyText(empty)
            }
            .padding(.bottom, 96)
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
            CodexComposerBar(
                draft: $agentDraft,
                placeholder: "Ask this agent...",
                isCompact: true,
                approvalSelection: $agentApproval,
                approvalOptions: CodexApprovalSelection.defaultOptions,
                modelSelection: $agentModel,
                modelOptions: modelOptions,
                reasoningSelection: $agentReasoning,
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
                    .font(theme.fonts.actionIcon)
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
        .codexGlass(RoundedRectangle(cornerRadius: theme.radii.composer, style: .continuous), role: .panel)
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
