import SwiftUI
import CodexCore

public struct CodexBackgroundTerminalActions: Sendable {
    public var refresh: @MainActor @Sendable () -> Void
    public var terminate: @MainActor @Sendable (String) -> Void
    public var clean: @MainActor @Sendable () -> Void

    public init(
        refresh: @escaping @MainActor @Sendable () -> Void,
        terminate: @escaping @MainActor @Sendable (String) -> Void,
        clean: @escaping @MainActor @Sendable () -> Void
    ) {
        self.refresh = refresh
        self.terminate = terminate
        self.clean = clean
    }
}

public struct CodexFloatingSummaryPanel: View {
    @Environment(\.codexAgentTheme) private var theme

    private let sideChat: CodexSideChatState?
    private let subagents: [CodexSubagentState]
    private let subagentCoordinator: CodexSubagentPresentationCoordinator?
    private let threadResourceInventory: CodexThreadResourceInventory?
    private let onOpenResource: ((CodexWorkspaceTabRequest) -> Void)?
    private let workspaceSummary: CodexWorkspaceSummaryContext?
    private let gitReviewSession: CodexGitReviewSession?
    private let backgroundTerminalActions: CodexBackgroundTerminalActions?
    private let chatTitle: String
    private let onEnvironmentHandoffCompletion: @MainActor @Sendable (CodexWorktreeHandoffCompletion) -> Void
    private let onSelectTab: (String) -> Void
    private let onOpenPlan: () -> Void
    private let onOpenReview: () -> Void
    private let onOpenBackgroundTerminalDetail: (String) -> Void

    public init(
        sideChat: CodexSideChatState?,
        subagents: [CodexSubagentState],
        subagentCoordinator: CodexSubagentPresentationCoordinator? = nil,
        threadResourceInventory: CodexThreadResourceInventory? = nil,
        workspaceSummary: CodexWorkspaceSummaryContext? = nil,
        gitReviewSession: CodexGitReviewSession? = nil,
        backgroundTerminalActions: CodexBackgroundTerminalActions? = nil,
        chatTitle: String = "Codex",
        onEnvironmentHandoffCompletion: @escaping @MainActor @Sendable (CodexWorktreeHandoffCompletion) -> Void = { _ in },
        onOpenPlan: @escaping () -> Void = {},
        onOpenReview: @escaping () -> Void = {},
        onOpenBackgroundTerminalDetail: @escaping (String) -> Void = { _ in },
        onOpenResource: ((CodexWorkspaceTabRequest) -> Void)? = nil,
        onSelectTab: @escaping (String) -> Void
    ) {
        self.sideChat = sideChat
        self.subagents = subagents
        self.subagentCoordinator = subagentCoordinator
        self.threadResourceInventory = threadResourceInventory
        self.onOpenResource = onOpenResource
        self.workspaceSummary = workspaceSummary
        self.gitReviewSession = gitReviewSession
        self.backgroundTerminalActions = backgroundTerminalActions
        self.chatTitle = chatTitle
        self.onEnvironmentHandoffCompletion = onEnvironmentHandoffCompletion
        self.onOpenPlan = onOpenPlan
        self.onOpenReview = onOpenReview
        self.onOpenBackgroundTerminalDetail = onOpenBackgroundTerminalDetail
        self.onSelectTab = onSelectTab
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            CodexThreadResourceSummaryView(
                inventory: summaryInventory,
                onOpen: openResource,
                excludedKinds: [.backgroundTerminal]
            )

            SummaryDivider()

            if let backgroundTerminalActions,
               let backgroundResources = summaryInventory?.resources(of: .backgroundTerminal),
               !backgroundResources.isEmpty {
                SummarySection(
                    title: "Background processes",
                    actions: AnyView(
                        Group {
                            Button("Refresh") { backgroundTerminalActions.refresh() }
                            Button("Clean all") { backgroundTerminalActions.clean() }
                        }
                    )
                ) {
                    ForEach(backgroundResources) { resource in
                        CodexThreadResourceRow(
                            resource: resource,
                            onOpen: openResource,
                            secondaryAction: resource.metadata.processID.map { processID in
                                { backgroundTerminalActions.terminate(processID) }
                            },
                            secondaryActionLabel: "Terminate background process"
                        )
                    }
                }
                SummaryDivider()
            }

            if let workspaceSummary {
                SummarySection(
                    title: "Environment",
                    actions: AnyView(environmentSectionActions(workspaceSummary))
                ) {
                    // The workspace summary can lag a project switch, so fall
                    // back to the branch the review snapshot already resolved.
                    // "HEAD" is the snapshot's placeholder for "no branch
                    // resolved", not a branch to advertise.
                    let branchName = workspaceSummary.gitBranch?.nilIfBlank
                        ?? gitReviewSession?.snapshot.branchName.nilIfBlank
                            .flatMap { $0 == "HEAD" ? nil : $0 }
                    CodexProjectEnvironmentPanel(
                        environment: CodexProjectEnvironmentState(
                            selection: workspaceSummary.environmentModeTitle == "Worktree"
                                ? .worktree : .local,
                            workspacePath: workspaceSummary.workspacePath,
                            branchName: branchName,
                            worktreePath: workspaceSummary.environmentModeTitle == "Worktree"
                                ? workspaceSummary.workspacePath : nil,
                            runtimeInfo: workspaceSummary.environmentInfo
                        ),
                        threadTitle: chatTitle,
                        provider: CodexLocalProjectEnvironmentProvider(
                            workspaceURL: URL(fileURLWithPath: workspaceSummary.workspacePath)
                        ),
                        onCompletion: onEnvironmentHandoffCompletion
                    )
                    .id(workspaceSummary.workspacePath)

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

        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .frame(width: theme.spacing.summaryPanelWidth, alignment: .topLeading)
        .fixedSize(horizontal: true, vertical: false)
        .codexGlass(RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous), role: .panel)
    }

    private var summaryInventory: CodexThreadResourceInventory? {
        threadResourceInventory
            ?? CodexThreadResourceFallbackInventory.make(
                threadID: ThreadID("workspace"),
                workspaceSummary: workspaceSummary,
                subagents: subagents,
                sideChat: sideChat,
                review: gitReviewSession
            )
    }

    private func openResource(_ request: CodexWorkspaceTabRequest) {
        if let onOpenResource {
            onOpenResource(request)
            return
        }
        // Keep the legacy callback source-compatible for hosts that have not
        // adopted the typed seam yet. New callers always receive the request.
        guard let resource = summaryInventory?.resource(id: request.resourceID) else {
            onSelectTab(request.resourceID)
            return
        }
        switch resource.kind {
        case .plan:
            onOpenPlan()
        case .review:
            onOpenReview()
        case .backgroundTerminal:
            if let processID = resource.metadata.processID {
                onOpenBackgroundTerminalDetail(processID)
            }
        case .subagent, .sideChat:
            if let childID = resource.metadata.childThreadID {
                onSelectTab(childID.rawValue)
            } else if resource.kind == .sideChat {
                onSelectTab(resource.id)
            }
        default:
            onSelectTab(request.resourceID)
        }
    }

    /// Section-header actions for Environment. Only what this app can actually
    /// perform on the checkout appears here.
    @ViewBuilder
    private func environmentSectionActions(
        _ summary: CodexWorkspaceSummaryContext
    ) -> some View {
        if gitReviewSession != nil {
            Button("Open Review") {
                onOpenReview()
            }
            Divider()
        }
        if summary.gitBranch?.nilIfBlank != nil || gitReviewSession?.snapshot.branchName.nilIfBlank != nil {
            if gitReviewSession != nil {
                Button("Commit or push") { onOpenReview() }
                Button("Create pull request") { onOpenReview() }
            } else {
                Button("Commit or push") {}
                    .disabled(true)
                Button("Create pull request") {}
                    .disabled(true)
            }
            Divider()
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(
                nil,
                inFileViewerRootedAtPath: summary.workspacePath
            )
        }
        Button("Copy path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(summary.workspacePath, forType: .string)
        }
    }
}

private struct SummarySection<Content: View>: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var isExpanded = true
    @State private var isHovered = false

    let title: String
    /// Section header menu. A section with nothing to offer shows no button at
    /// all rather than a decorative one.
    let actions: AnyView?
    let content: Content

    init(
        title: String,
        actions: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.actions = actions
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

                if let actions {
                    Menu {
                        actions
                    } label: {
                        Image(systemName: "plus")
                            .font(theme.fonts.actionIcon)
                            .foregroundStyle(theme.colors.textTertiary)
                            .frame(width: 24, height: 24)
                            .opacity(isHovered ? 1 : 0.72)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("\(title) actions")
                    .accessibilityLabel("\(title) actions")
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
    @ObservedObject private var workspaceTabs: CodexWorkspaceTabs
    private let placement: CodexWorkspaceTabPlacement
    private let panelHeight: CGFloat
    @Binding private var sideChatDraft: String
    private let width: Binding<CGFloat>?
    private let browserSessions: [CodexBrowserSession]
    private let mountedBrowserSessions: [CodexBrowserSession]
    private let threadResourceInventory: CodexThreadResourceInventory?
    private let onOpenResource: ((CodexWorkspaceTabRequest) -> Void)?
    private let isSideChatSending: Bool
    private let canSendSideChatMessage: Bool
    private let onSendSideChatMessage: () -> Void
    private let onInterruptSideChatMessage: () -> Void
    private let onOpenTerminal: () -> Void
    private let onOpenBrowser: () -> Void
    private let onOpenFiles: () -> Void
    private let onCloseBrowser: (String) -> Void
    private let showsCloseButton: Bool
    private let onClose: () -> Void
    @State private var resizeStartWidth: CGFloat?
    @State private var liveResizeWidth: CGFloat?

    public init(
        tabs: [CodexAgentPanelTab],
        workspaceTabs: CodexWorkspaceTabs,
        browserSessions: [CodexBrowserSession] = [],
        mountedBrowserSessions: [CodexBrowserSession] = [],
        threadResourceInventory: CodexThreadResourceInventory? = nil,
        onOpenResource: ((CodexWorkspaceTabRequest) -> Void)? = nil,
        modelOptions: [CodexModelSelection] = CodexModelSelection.defaultOptions,
        sideChatDraft: Binding<String> = .constant(""),
        isSideChatSending: Bool = false,
        canSendSideChatMessage: Bool = false,
        onSendSideChatMessage: @escaping () -> Void = {},
        onInterruptSideChatMessage: @escaping () -> Void = {},
        onOpenTerminal: @escaping () -> Void = {},
        onOpenBrowser: @escaping () -> Void = {},
        onOpenFiles: @escaping () -> Void = {},
        onCloseBrowser: @escaping (String) -> Void = { _ in },
        showsCloseButton: Bool = true,
        onClose: @escaping () -> Void,
        placement: CodexWorkspaceTabPlacement = .right,
        panelHeight: CGFloat = 280
    ) {
        self.tabs = tabs
        self._workspaceTabs = ObservedObject(wrappedValue: workspaceTabs)
        self.placement = placement
        self.panelHeight = panelHeight
        self._sideChatDraft = sideChatDraft
        self.width = nil
        self.browserSessions = browserSessions
        self.mountedBrowserSessions = mountedBrowserSessions
        self.threadResourceInventory = threadResourceInventory
        self.onOpenResource = onOpenResource
        self.isSideChatSending = isSideChatSending
        self.canSendSideChatMessage = canSendSideChatMessage
        self.onSendSideChatMessage = onSendSideChatMessage
        self.onInterruptSideChatMessage = onInterruptSideChatMessage
        self.onOpenTerminal = onOpenTerminal
        self.onOpenBrowser = onOpenBrowser
        self.onOpenFiles = onOpenFiles
        self.onCloseBrowser = onCloseBrowser
        self.showsCloseButton = showsCloseButton
        self.onClose = onClose
    }

    public init(
        tabs: [CodexAgentPanelTab],
        workspaceTabs: CodexWorkspaceTabs,
        width: Binding<CGFloat>,
        browserSessions: [CodexBrowserSession] = [],
        mountedBrowserSessions: [CodexBrowserSession] = [],
        threadResourceInventory: CodexThreadResourceInventory? = nil,
        onOpenResource: ((CodexWorkspaceTabRequest) -> Void)? = nil,
        modelOptions: [CodexModelSelection] = CodexModelSelection.defaultOptions,
        sideChatDraft: Binding<String> = .constant(""),
        isSideChatSending: Bool = false,
        canSendSideChatMessage: Bool = false,
        onSendSideChatMessage: @escaping () -> Void = {},
        onInterruptSideChatMessage: @escaping () -> Void = {},
        onOpenTerminal: @escaping () -> Void = {},
        onOpenBrowser: @escaping () -> Void = {},
        onOpenFiles: @escaping () -> Void = {},
        onCloseBrowser: @escaping (String) -> Void = { _ in },
        showsCloseButton: Bool = true,
        onClose: @escaping () -> Void,
        placement: CodexWorkspaceTabPlacement = .right,
        panelHeight: CGFloat = 280
    ) {
        self.tabs = tabs
        self._workspaceTabs = ObservedObject(wrappedValue: workspaceTabs)
        self.placement = placement
        self.panelHeight = panelHeight
        self._sideChatDraft = sideChatDraft
        self.width = width
        self.browserSessions = browserSessions
        self.mountedBrowserSessions = mountedBrowserSessions
        self.threadResourceInventory = threadResourceInventory
        self.onOpenResource = onOpenResource
        self.isSideChatSending = isSideChatSending
        self.canSendSideChatMessage = canSendSideChatMessage
        self.onSendSideChatMessage = onSendSideChatMessage
        self.onInterruptSideChatMessage = onInterruptSideChatMessage
        self.onOpenTerminal = onOpenTerminal
        self.onOpenBrowser = onOpenBrowser
        self.onOpenFiles = onOpenFiles
        self.onCloseBrowser = onCloseBrowser
        self.showsCloseButton = showsCloseButton
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().overlay(theme.colors.border)
            panelContent
        }
        .frame(
            width: placement == .right ? panelWidth : nil,
            height: placement == .bottom ? panelHeight : nil,
            alignment: .topLeading
        )
        .frame(
            maxWidth: placement == .bottom ? .infinity : nil,
            maxHeight: placement == .right ? .infinity : nil
        )
        .background(theme.colors.surface.opacity(theme.effects.surfaceOpacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CodexWorkspaceTabAccessibility.panelLabel(placement))
        .overlay(alignment: .leading) {
            resizeHandle
        }
        .animation(nil, value: panelWidth)
        .onAppear {
            ensureSelection()
        }
        .onChange(of: legacyTabIDs) { _, _ in
            ensureSelection()
        }
    }

    // The deck keeps every recent chat's browser/files surfaces mounted at once;
    // terminals are workspace-tab adapters and use the same content host below.
    private var deckBrowserSessions: [CodexBrowserSession] {
        mountedBrowserSessions.isEmpty ? browserSessions : mountedBrowserSessions
    }

    @ViewBuilder
    private var panelContent: some View {
        ZStack {
            if placement == .right {
                ForEach(deckBrowserSessions) { session in
                    CodexBrowserToolView(session: session)
                        .toolPanelVisibility(isSelected: isSelectedLegacy(session.id))
                        .id(session.id)
                }

            }

            let panelTabIDs = Set(orderedTabs.compactMap(\.workspaceTabID))
            ForEach(workspaceTabs.snapshot.instances.filter {
                $0.isMaterialized
                    && panelTabIDs.contains($0.id)
                    && (activeTab == .workspace($0.id)
                        || workspaceTabs.retainsContentWhenHidden($0.id))
            }) { instance in
                let isSelected = activeTab == .workspace(instance.id)
                if let content = workspaceTabs.content(for: instance.id) {
                    content
                        .toolPanelVisibility(isSelected: isSelected)
                        .onAppear {
                            workspaceTabs.setVisibility(isSelected, for: instance.id)
                        }
                        .onChange(of: isSelected) { _, visible in
                            workspaceTabs.setVisibility(visible, for: instance.id)
                        }
                        .id(instance.contentID.rawValue)
                }
            }

            if selectedBrowserSession == nil,
               activeWorkspaceTabID == nil {
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


            if let id = activeWorkspaceTabID,
               workspaceTabs.snapshot.instance(id: id)?.isMaterialized == false {
                if workspaceTabs.isAvailable(id) {
                    ProgressView("Restoring tab…")
                        .task(id: id) { workspaceTabs.activate(id) }
                } else {
                    Text("This tab is unavailable in the current workspace.")
                        .foregroundStyle(theme.colors.textTertiary)
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
        .frame(width: placement == .right ? 14 : 0)
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
        guard selectedBrowserSession == nil, activeWorkspaceTabID == nil else { return nil }
        guard let id = activeTab?.legacyID else { return nil }
        return tabs.first { $0.id == id }
    }

    private var activeTab: CodexWorkspaceTabHandle? {
        workspaceTabs.activeTab(in: placement)
    }

    private var activeWorkspaceTabID: CodexWorkspaceTabID? {
        activeTab?.workspaceTabID
    }

    private func isSelectedLegacy(_ id: String) -> Bool {
        activeTab == .legacy(id)
    }

    private var selectedBrowserSession: CodexBrowserSession? {
        browserSessions.first { isSelectedLegacy($0.id) }
    }

    private var legacyTabIDs: [String] {
        browserSessions.map(\.id)
            + tabs.map(\.id)
    }

    private var orderedTabs: [CodexWorkspaceTabHandle] {
        workspaceTabs.orderedTabs(in: placement)
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            GeometryReader { geometry in
                let tabWidth = CodexAgentPanelTabStripLayout.tabWidth(
                    availableWidth: geometry.size.width,
                    tabCount: orderedTabs.count
                )

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(orderedTabs) { handle in
                            tabButton(for: handle, width: tabWidth)
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
                if let activeWorkspaceTabID,
                   let activeInstance = workspaceTabs.snapshot.instance(id: activeWorkspaceTabID) {
                    Button {
                        workspaceTabs.move(activeWorkspaceTabID, to: placement.other)
                    } label: {
                        Image(systemName: placement == .right
                            ? "rectangle.bottomhalf.inset.filled"
                            : "rectangle.righthalf.inset.filled")
                            .font(theme.fonts.label)
                            .foregroundStyle(theme.colors.textSecondary)
                            .frame(width: theme.spacing.iconLarge, height: theme.spacing.iconLarge)
                    }
                    .buttonStyle(.plain)
                    .help(
                        "\(CodexWorkspaceTabAccessibility.moveLabel(title: activeInstance.title, to: placement.other)) (\(CodexWorkspaceTabAccessibility.moveShortcut(for: placement)))"
                    )
                    .accessibilityLabel(CodexWorkspaceTabAccessibility.moveLabel(title: activeInstance.title, to: placement.other))
                    .keyboardShortcut(
                        placement == .right ? "]" : "[",
                        modifiers: [.command, .option]
                    )
                }

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
                        Image(systemName: placement == .right
                            ? "sidebar.right"
                            : "rectangle.bottomthird.inset.filled")
                            .font(theme.fonts.label)
                            .foregroundStyle(theme.colors.textTertiary)
                            .frame(width: theme.spacing.iconLarge, height: theme.spacing.iconLarge)
                    }
                    .buttonStyle(.plain)
                    .codexGlass(Circle(), role: .control)
                    .help(placement == .right ? "Close side panel" : "Close bottom panel")
                    .accessibilityLabel(placement == .right ? "Close side panel" : "Close bottom panel")
                }
            }
            .padding(.trailing, 8)
        }
        .frame(height: theme.spacing.toolbarHeight)
    }

    @ViewBuilder
    private func tabButton(for handle: CodexWorkspaceTabHandle, width: CGFloat) -> some View {
        switch handle {
        case .workspace(let id):
            if let tab = workspaceTabs.snapshot.instance(id: id) {
                AgentPanelTabButton(
                    title: tab.title,
                    systemImage: tab.systemImage,
                    isSelected: activeTab == handle,
                    width: width,
                    showsLeadingDivider: showsLeadingDivider(for: handle),
                    closeAction: { workspaceTabs.close(id) }
                ) { workspaceTabs.activate(id) }
                .contextMenu {
                    Button(CodexWorkspaceTabAccessibility.moveLabel(title: tab.title, to: placement.other)) {
                        workspaceTabs.move(id, to: placement.other)
                    }
                    Button(CodexWorkspaceTabAccessibility.closeLabel(title: tab.title), role: .destructive) {
                        workspaceTabs.close(id)
                    }
                }
            }
        case .legacy(let id):
            if let session = browserSessions.first(where: { $0.id == id }) {
                BrowserPanelTabButton(
                    session: session,
                    isSelected: activeTab == handle,
                    width: width,
                    showsLeadingDivider: showsLeadingDivider(for: handle),
                    closeAction: { onCloseBrowser(id) }
                ) { workspaceTabs.activateLegacy(id) }
            } else if let tab = tabs.first(where: { $0.id == id }) {
                AgentPanelTabButton(
                    title: tab.title,
                    systemImage: tab.systemImage,
                    isSelected: activeTab == handle,
                    width: width,
                    showsLeadingDivider: showsLeadingDivider(for: handle),
                    closeAction: nil
                ) { workspaceTabs.activateLegacy(id) }
            }
        }
    }

    private func showsLeadingDivider(for handle: CodexWorkspaceTabHandle) -> Bool {
        guard let index = orderedTabs.firstIndex(of: handle), index > 0 else {
            return false
        }
        return CodexAgentPanelTabStripLayout.showsLeadingDivider(
            tabID: displayID(handle),
            precedingTabID: displayID(orderedTabs[index - 1]),
            selectedTabID: activeTab.map(displayID)
        )
    }

    private func displayID(_ handle: CodexWorkspaceTabHandle) -> String {
        switch handle {
        case .workspace(let id): "workspace:\(id.rawValue.uuidString)"
        case .legacy(let id): "legacy:\(id)"
        }
    }

    private var toolLauncher: some View {
        CodexThreadResourceNewTabView(
            inventory: threadResourceInventory,
            onOpen: { request in onOpenResource?(request) },
            onOpenTool: openTool
        )
    }

    private func ensureSelection() {
        workspaceTabs.reconcileLegacy(legacyTabIDs)
        if activeTab == nil, !orderedTabs.isEmpty {
            workspaceTabs.setOpen(true, placement: placement)
        }
        workspaceTabs.restoreFocus()
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
                HStack(spacing: 4) {
                    Image(systemName: systemImage)
                        .font(theme.fonts.caption)
                    Text(title)
                        .font(theme.fonts.label)
                        .lineLimit(1)
                }
                .foregroundStyle(isSelected ? theme.colors.textPrimary : theme.colors.textSecondary)
                .padding(.leading, 7)
                .padding(.trailing, closeAction == nil ? 7 : 25)
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

    var body: some View {
        ZStack(alignment: .bottom) {
            switch tab {
            case .sideChat(let sideChat):
                transcriptPanel(
                    transcript: sideChat.transcript,
                    transcriptID: sideChat.id,
                    empty: "Side chat is ready for a focused branch of the parent conversation."
                )
            }

            compactComposer(for: tab)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
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
