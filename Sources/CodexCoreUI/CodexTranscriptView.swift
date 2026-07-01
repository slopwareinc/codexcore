import SwiftUI

@MainActor
private enum CodexMessageHoverReveal {
    static let hideDelay: Duration = .milliseconds(150)

    static func reveal(
        _ isHovered: Binding<Bool>,
        hideTask: Binding<Task<Void, Never>?>,
        hovering: Bool,
        scrollActive: Bool
    ) {
        if scrollActive {
            hideTask.wrappedValue?.cancel()
            if isHovered.wrappedValue {
                isHovered.wrappedValue = false
            }
            return
        }
        hideTask.wrappedValue?.cancel()
        if hovering {
            isHovered.wrappedValue = true
            return
        }
        hideTask.wrappedValue = Task {
            try? await Task.sleep(for: hideDelay)
            guard !Task.isCancelled else { return }
            isHovered.wrappedValue = false
        }
    }
}

private struct CodexTranscriptScrollActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var codexTranscriptScrollActive: Bool {
        get { self[CodexTranscriptScrollActiveKey.self] }
        set { self[CodexTranscriptScrollActiveKey.self] = newValue }
    }
}

public struct CodexTranscriptView<EmptyContent: View>: View {
    private let messages: [CodexChatMessage]
    private let transcriptID: String?
    private let lifecycleEvents: [CodexAgentLifecycleEvent]
    private let activeTurn: CodexActiveTurnState?
    private let emptyContent: EmptyContent
    private let onCloseMessage: ((UUID) -> Void)?
    private let onOpenMCPDetails: (() -> Void)?
    private let onEditUserMessage: ((String) -> Void)?

    @Environment(\.codexAgentTheme) private var theme
    @State private var timelineItems: [CodexTranscriptTimelineItem] = []
    @State private var messageLookup: [UUID: CodexChatMessage] = [:]
    @State private var scrollTrigger: CodexTranscriptScrollTrigger = .empty
    @State private var isPinnedToBottom = true
    @State private var pendingScrollRequest: DispatchWorkItem?
    @State private var viewportHeight: CGFloat = 720
    @State private var lastScrollBottomY: CGFloat = 0
    @State private var isTranscriptScrolling = false
    @State private var scrollEndTask: Task<Void, Never>?

    public init(
        messages: [CodexChatMessage],
        transcriptID: String? = nil,
        lifecycleEvents: [CodexAgentLifecycleEvent] = [],
        activeTurn: CodexActiveTurnState? = nil,
        onCloseMessage: ((UUID) -> Void)? = nil,
        onOpenMCPDetails: (() -> Void)? = nil,
        onEditUserMessage: ((String) -> Void)? = nil,
        @ViewBuilder emptyContent: () -> EmptyContent
    ) {
        self.messages = messages
        self.transcriptID = transcriptID
        self.lifecycleEvents = lifecycleEvents
        self.activeTurn = activeTurn
        self.onCloseMessage = onCloseMessage
        self.onOpenMCPDetails = onOpenMCPDetails
        self.onEditUserMessage = onEditUserMessage
        self.emptyContent = emptyContent()
    }

    private var transcriptInput: CodexTranscriptInput {
        CodexTranscriptInput(
            transcriptID: transcriptID,
            messages: messages,
            lifecycleEvents: lifecycleEvents,
            activeTurn: activeTurn
        )
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if timelineItems.isEmpty {
                    emptyContent
                        .frame(maxWidth: .infinity, minHeight: 420)
                        .padding(.horizontal, 28)
                } else {
                    LazyVStack(alignment: .leading, spacing: theme.spacing.rowGap) {
                        ForEach(timelineItems) { item in
                            CodexTranscriptTimelineRow(
                                item: item,
                                message: item.messageID.flatMap { messageLookup[$0] },
                                onCloseMessage: onCloseMessage,
                                onOpenMCPDetails: onOpenMCPDetails,
                                onEditUserMessage: onEditUserMessage
                            )
                            .equatable()
                        }
                        if let activeTurn {
                            CodexActiveTurnRow(state: activeTurn)
                                .equatable()
                                .id("active-turn")
                        }
                        bottomAnchor
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 24)
                    .padding(.bottom, 28)
                    .frame(maxWidth: theme.spacing.transcriptOuterMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
            .environment(\.codexTranscriptScrollActive, isTranscriptScrolling)
            .id(scrollTrigger.transcriptIdentity)
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .preference(key: CodexTranscriptViewportHeightPreferenceKey.self, value: geometry.size.height)
                }
            }
            .coordinateSpace(name: Self.scrollCoordinateSpace)
            .scrollContentBackground(.hidden)
            .onPreferenceChange(CodexTranscriptViewportHeightPreferenceKey.self) { height in
                guard height > 0 else { return }
                viewportHeight = height
            }
            .onPreferenceChange(CodexTranscriptBottomPreferenceKey.self) { bottomY in
                guard bottomY > 0 else { return }
                if abs(bottomY - lastScrollBottomY) > 0.5 {
                    lastScrollBottomY = bottomY
                    isTranscriptScrolling = true
                    scrollEndTask?.cancel()
                    scrollEndTask = Task {
                        try? await Task.sleep(for: .milliseconds(180))
                        guard !Task.isCancelled else { return }
                        isTranscriptScrolling = false
                    }
                }
                let pinned = bottomY <= viewportHeight + Self.bottomPinTolerance
                guard pinned != isPinnedToBottom else { return }
                isPinnedToBottom = pinned
            }
            .onAppear {
                requestScroll(proxy, animated: false, force: true)
            }
            .onChange(of: scrollTrigger) { oldValue, newValue in
                let isInitialLoad = oldValue.isEmpty && !newValue.isEmpty
                requestScroll(
                    proxy,
                    animated: !isInitialLoad && newValue.hasStructureChange(comparedTo: oldValue),
                    force: isInitialLoad
                )
            }
        }
        .task(id: transcriptInput) {
            refreshTimeline(for: transcriptInput)
        }
    }

    private func refreshTimeline(for input: CodexTranscriptInput) {
        let cacheKey = input.cacheKey(lifecycleEvents: lifecycleEvents)
        if let cachedItems = CodexTranscriptTimelineCache.cachedItems(for: cacheKey) {
            timelineItems = cachedItems
        } else {
            let built = CodexTranscriptTimelineBuilder.build(
                messages: messages,
                lifecycleEvents: lifecycleEvents
            )
            CodexTranscriptTimelineCache.store(key: cacheKey, items: built)
            timelineItems = built
        }
        messageLookup = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        scrollTrigger = CodexTranscriptScrollTrigger(
            transcriptID: transcriptID,
            timelineItems: timelineItems,
            messageLookup: messageLookup,
            activeTurn: activeTurn
        )
    }

    private static var bottomAnchor: String { "transcript-bottom" }
    private static var scrollCoordinateSpace: String { "codex-transcript-scroll" }
    private static var bottomPinTolerance: CGFloat { 80 }
    private static var scrollDebounceDelay: TimeInterval { 0.08 }

    private var bottomAnchor: some View {
        Color.clear
            .frame(height: 8)
            .id(Self.bottomAnchor)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: CodexTranscriptBottomPreferenceKey.self,
                        value: geometry.frame(in: .named(Self.scrollCoordinateSpace)).maxY
                    )
                }
            )
    }

    private func requestScroll(_ proxy: ScrollViewProxy, animated: Bool, force: Bool = false) {
        guard force || isPinnedToBottom else { return }

        pendingScrollRequest?.cancel()
        let request = DispatchWorkItem {
            guard force || isPinnedToBottom else { return }
            scroll(proxy, animated: animated)
        }
        pendingScrollRequest = request
        guard !force else {
            DispatchQueue.main.async(execute: request)
            return
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.scrollDebounceDelay,
            execute: request
        )
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }
}

private struct CodexTranscriptScrollTrigger: Equatable {
    static let empty = CodexTranscriptScrollTrigger(
        transcriptID: nil,
        itemCount: 0,
        firstItemID: nil,
        lastItemID: nil,
        streamingVersion: 0,
        activeTurnVersion: 0
    )

    var transcriptID: String?
    var itemCount: Int
    var firstItemID: String?
    var lastItemID: String?
    var streamingVersion: Int
    var activeTurnVersion: Int

    init(
        transcriptID: String?,
        timelineItems: [CodexTranscriptTimelineItem],
        messageLookup: [UUID: CodexChatMessage],
        activeTurn: CodexActiveTurnState?
    ) {
        self.init(
            transcriptID: transcriptID,
            itemCount: timelineItems.count,
            firstItemID: timelineItems.first?.id,
            lastItemID: timelineItems.last?.id,
            streamingVersion: timelineItems.reduce(0) { partialResult, item in
                partialResult &+ item.streamingContentLength(in: messageLookup)
            },
            activeTurnVersion: activeTurn == nil ? 0 : 1
        )
    }

    private init(
        transcriptID: String?,
        itemCount: Int,
        firstItemID: String?,
        lastItemID: String?,
        streamingVersion: Int,
        activeTurnVersion: Int
    ) {
        self.transcriptID = transcriptID
        self.itemCount = itemCount
        self.firstItemID = firstItemID
        self.lastItemID = lastItemID
        self.streamingVersion = streamingVersion
        self.activeTurnVersion = activeTurnVersion
    }

    var isEmpty: Bool {
        itemCount == 0 && activeTurnVersion == 0
    }

    var transcriptIdentity: String {
        transcriptID ?? firstItemID ?? "empty-transcript"
    }

    func hasStructureChange(comparedTo oldValue: Self) -> Bool {
        itemCount != oldValue.itemCount
            || lastItemID != oldValue.lastItemID
            || activeTurnVersion != oldValue.activeTurnVersion
    }
}

private struct CodexTranscriptViewportHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct CodexTranscriptBottomPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct CodexTranscriptTimelineRow: View, Equatable {
    @Environment(\.codexAgentTheme) private var theme

    let item: CodexTranscriptTimelineItem
    let message: CodexChatMessage?
    let onCloseMessage: ((UUID) -> Void)?
    let onOpenMCPDetails: (() -> Void)?
    let onEditUserMessage: ((String) -> Void)?

    nonisolated static func == (lhs: CodexTranscriptTimelineRow, rhs: CodexTranscriptTimelineRow) -> Bool {
        lhs.item == rhs.item && lhs.message == rhs.message
    }

    var body: some View {
        switch item {
        case .messageRef:
            if let message {
                CodexMessageRow(
                    message: message,
                    onCloseMessage: onCloseMessage,
                    onOpenMCPDetails: onOpenMCPDetails,
                    onEditUserMessage: onEditUserMessage
                )
            }
        case .completedWorkTrace(_, let trace):
            CodexAgentRow(visibility: .hidden) {
                CodexCompletedWorkTraceView(trace: trace)
            }
        case .operationAggregate(_, let rows):
            CodexAgentRow(visibility: .hidden) {
                CodexOperationSummaryCard(rows: rows)
            }
        case .fileChangeAggregate(_, let changes):
            CodexAgentRow {
                CodexAggregateFileChangeCard(changes: changes)
            }
        case .assistantLifecycle(_, let events):
            CodexAgentRow(visibility: .hidden) {
                CodexSubagentRunInlineView(events: events)
            }
        case .assistantBlock(_, let block):
            CodexAgentRow(visibility: .hidden) {
                CodexBlockView(block: block)
                    .equatable()
            }
        case .assistantStreamingWorking(_, let text, let isEmpty):
            CodexAgentRow(visibility: .hidden) {
                HStack(alignment: .bottom, spacing: 9) {
                    if isEmpty {
                        CodexThinkingShimmer()
                    } else {
                        Text(verbatim: text)
                            .font(theme.fonts.chat)
                            .foregroundStyle(theme.colors.textPrimary)
                            .lineSpacing(theme.spacing.chatLineSpacing)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    CodexWorkingSpinnerBadge()
                        .padding(.bottom, isEmpty ? 1 : 2)
                }
            }
        case .lifecycle(let event):
            CodexAgentLifecycleBlock(event: event)
        }
    }
}

private struct CodexActiveTurnRow: View, Equatable {
    let state: CodexActiveTurnState

    nonisolated static func == (lhs: CodexActiveTurnRow, rhs: CodexActiveTurnRow) -> Bool {
        lhs.state == rhs.state
    }

    var body: some View {
        CodexTurnWorkingBlock(state: state)
    }
}

public struct CodexAgentLifecycleBlock: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var isExpanded = false

    private let event: CodexAgentLifecycleEvent

    public init(event: CodexAgentLifecycleEvent) {
        self.event = event
    }

    public var body: some View {
        CodexAgentRow(showAvatar: false) {
            VStack(alignment: .leading, spacing: 9) {
                Button {
                    guard isCollapsible else { return }
                    withAnimation(.snappy(duration: theme.animations.snappyDuration)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(alignment: .top, spacing: 9) {
                        statusIcon
                            .frame(width: theme.spacing.iconMedium, height: theme.spacing.iconMedium)
                            .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) {
                                Text(event.title)
                                    .font(theme.fonts.label)
                                    .foregroundStyle(theme.colors.textSecondary)
                                    .lineLimit(1)
                                if !event.agentNames.isEmpty {
                                    Text(agentCountLabel)
                                        .font(theme.fonts.caption)
                                        .foregroundStyle(theme.colors.textTertiary)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(theme.colors.surfaceElevated.opacity(theme.effects.textFaintOpacity), in: Capsule())
                                }
                            }

                            if !isExpanded, !detailPreview.isEmpty {
                                Text(detailPreview)
                                    .font(theme.fonts.caption)
                                    .foregroundStyle(theme.colors.textTertiary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 0)

                        Text(event.createdAt, format: .dateTime.hour().minute())
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.textTertiary)

                        Image(systemName: "chevron.right")
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.textTertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .opacity(isCollapsible ? 1 : 0.25)
                            .padding(.top, 2)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 9) {
                        if !event.detail.isEmpty {
                            Text(event.detail)
                                .font(theme.fonts.chat)
                                .foregroundStyle(theme.colors.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if !event.agentNames.isEmpty {
                            HStack(spacing: 7) {
                                ForEach(event.agentNames, id: \.self) { name in
                                    HStack(spacing: 5) {
                                        Image(systemName: "person.crop.circle.badge.checkmark")
                                            .font(theme.fonts.caption)
                                        Text(name)
                                            .font(theme.fonts.caption)
                                    }
                                    .foregroundStyle(theme.colors.textSecondary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(theme.colors.surfaceElevated.opacity(theme.effects.glassOpacity), in: Capsule())
                                    .overlay(Capsule().stroke(theme.colors.border, lineWidth: 1))
                                }
                            }
                        }
                    }
                    .padding(.leading, 25)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(theme.colors.surface.opacity(theme.effects.glassOpacity), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                    .stroke(theme.colors.border, lineWidth: 1)
            )
            .frame(maxWidth: theme.spacing.cardMaxWidth, alignment: .leading)
        }
    }

    private var isCollapsible: Bool {
        !event.detail.isEmpty || !event.agentNames.isEmpty
    }

    private var detailPreview: String {
        let normalized = event.detail
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > 140 else { return normalized }
        return String(normalized.prefix(140)) + "..."
    }

    private var agentCountLabel: String {
        event.agentNames.count == 1 ? "1 agent" : "\(event.agentNames.count) agents"
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch event.status {
        case .spawning:
            Image(systemName: "sparkles")
                .foregroundStyle(theme.colors.accent)
        case .running:
            Circle()
                .fill(theme.colors.running)
                .frame(width: 7, height: 7)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(theme.colors.success)
        case .closed:
            Image(systemName: "archivebox.fill")
                .foregroundStyle(theme.colors.textTertiary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.colors.danger)
        }
    }
}

public struct CodexMessageRow: View {
    private let message: CodexChatMessage
    private let assistantName: String
    private let onCloseMessage: ((UUID) -> Void)?
    private let onOpenMCPDetails: (() -> Void)?
    private let onEditUserMessage: ((String) -> Void)?

    public init(
        message: CodexChatMessage,
        assistantName: String = "Codex",
        onCloseMessage: ((UUID) -> Void)? = nil,
        onOpenMCPDetails: (() -> Void)? = nil,
        onEditUserMessage: ((String) -> Void)? = nil
    ) {
        self.message = message
        self.assistantName = assistantName
        self.onCloseMessage = onCloseMessage
        self.onOpenMCPDetails = onOpenMCPDetails
        self.onEditUserMessage = onEditUserMessage
    }

    public var body: some View {
        switch message.role {
        case .system:
            CodexSystemMessageView(text: message.text)
        case .user:
            CodexUserMessageView(message: message, onEdit: onEditUserMessage)
        case .terminal:
            if let run = message.commandRun {
                CodexAgentRow {
                    CodexCommandCard(run: run)
                }
            }
        case .fileChange:
            if let change = message.fileChange {
                CodexAgentRow {
                    CodexFileChangeCard(change: change)
                }
            }
        case .plan:
            if let plan = message.planUpdate {
                CodexAgentRow {
                    CodexPlanCard(plan: plan)
                }
            }
        case .tool:
            if let toolCall = message.toolCall {
                CodexAgentRow {
                    CodexToolCallCard(toolCall: toolCall)
                }
            }
        case .notice:
            if let notice = message.notice {
                if let model = CodexStatusPanelModel(notice: notice) {
                    CodexAgentRow {
                        CodexStatusPanelCard(model: model, onClose: closeAction)
                    }
                } else if let model = CodexMCPStatusPanelModel(notice: notice) {
                    CodexAgentRow {
                        CodexMCPStatusPanelCard(
                            model: model,
                            onClose: closeAction,
                            onOpenDetails: onOpenMCPDetails
                        )
                    }
                } else {
                    CodexAgentRow {
                        CodexNoticeCard(notice: notice)
                    }
                }
            }
        case .reasoning:
            if let block = message.reasoningBlock {
                CodexAgentRow {
                    CodexReasoningCard(block: block)
                }
            }
        case .assistant:
            CodexAgentRow(visibility: .hidden) {
                CodexAssistantMessageView(message: message, assistantName: assistantName)
            }
        }
    }

    private var closeAction: (() -> Void)? {
        guard let onCloseMessage else { return nil }
        return { onCloseMessage(message.id) }
    }
}

public enum CodexAgentAvatarVisibility {
    case visible
    case placeholder
    case hidden
}

/// Left-aligned agent row with the Codex avatar.
public struct CodexAgentRow<Content: View>: View {
    @Environment(\.codexAgentTheme) private var theme

    private let content: Content
    private let visibility: CodexAgentAvatarVisibility

    public init(visibility: CodexAgentAvatarVisibility = .visible, @ViewBuilder content: () -> Content) {
        self.visibility = visibility
        self.content = content()
    }

    public init(showAvatar: Bool, @ViewBuilder content: () -> Content) {
        self.visibility = showAvatar ? .visible : .placeholder
        self.content = content()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            switch visibility {
            case .visible:
                CodexBrandMark(size: 28)
                    .padding(.top, 2)
            case .placeholder:
                Circle()
                    .fill(theme.colors.surfaceElevated)
                    .frame(width: theme.spacing.iconLarge, height: theme.spacing.iconLarge)
                    .overlay(Image(systemName: "point.3.connected.trianglepath.dotted").font(theme.fonts.caption))
                    .foregroundStyle(theme.colors.textTertiary)
                    .padding(.top, 2)
            case .hidden:
                Color.clear
                    .frame(width: 28, height: 28)
                    .padding(.top, 2)
            }
            content
            Spacer(minLength: 32)
        }
    }
}

public struct CodexAssistantMessageView: View {
    @Environment(\.codexAgentTheme) private var theme
    @Environment(\.codexTranscriptScrollActive) private var isTranscriptScrolling

    private let message: CodexChatMessage
    private let assistantName: String
    @State private var isHovered = false
    @State private var copied = false
    @State private var hideHoverTask: Task<Void, Never>?

    public init(message: CodexChatMessage, assistantName: String = "Codex") {
        self.message = message
        self.assistantName = assistantName
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.isStreaming {
                HStack(alignment: .bottom, spacing: 9) {
                    if message.text.isEmpty {
                        CodexThinkingShimmer()
                    } else {
                        StreamingAssistantText(text: message.text)
                    }
                    CodexWorkingSpinnerBadge()
                        .padding(.bottom, message.text.isEmpty ? 1 : 2)
                }
            } else {
                if let projected = message.projectedBlocks {
                    CodexAssistantContentView(
                        projectedBlocks: projected,
                        cacheNamespace: message.id.uuidString
                    )
                } else {
                    CodexAssistantContentView(
                        text: message.text,
                        isStreaming: false,
                        cacheNamespace: message.id.uuidString
                    )
                }
                if !turnEndActions.isEmpty {
                    CodexMessageMetaFooter(
                        timestamp: message.createdAt,
                        alignment: .leading,
                        actions: turnEndFooterActions,
                        isHovered: isHovered,
                        copied: $copied,
                        copyText: message.text,
                        onEdit: nil,
                        onHoverChanged: { updateHover($0) }
                    )
                }
            }
        }
        .frame(maxWidth: theme.spacing.cardMaxWidth, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { updateHover($0) }
    }

    private func updateHover(_ hovering: Bool) {
        CodexMessageHoverReveal.reveal(
            $isHovered,
            hideTask: $hideHoverTask,
            hovering: hovering,
            scrollActive: isTranscriptScrolling
        )
    }

    private var turnEndActions: [CodexLiveTurnModel.TurnEndAction] {
        CodexLiveTurnModel.turnEndActions(for: message)
    }

    private var turnEndFooterActions: [CodexMessageMetaFooter.Action] {
        turnEndActions.map {
            switch $0 {
            case .copy: .copy
            case .fork: .fork
            }
        }
    }
}

private struct CodexMessageMetaFooter: View {
    enum Action: Hashable {
        case copy
        case fork
        case edit
    }

    @Environment(\.codexAgentTheme) private var theme

    static let reservedHeight: CGFloat = 20

    let timestamp: Date
    let alignment: HorizontalAlignment
    let actions: [Action]
    let isHovered: Bool
    @Binding var copied: Bool
    let copyText: String
    let onEdit: (() -> Void)?
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if alignment == .trailing {
                Spacer(minLength: 0)
            }

            if alignment == .leading {
                timestampLabel
                actionButtons
            } else {
                actionButtons
                timestampLabel
            }

            if alignment == .leading {
                Spacer(minLength: 0)
            }
        }
        .frame(height: Self.reservedHeight)
        .frame(
            maxWidth: alignment == .trailing ? theme.spacing.userBubbleMaxWidth : theme.spacing.cardMaxWidth,
            alignment: frameAlignment
        )
        .contentShape(Rectangle())
        .onHover { onHoverChanged($0) }
    }

    private var frameAlignment: Alignment {
        alignment == .trailing ? .trailing : .leading
    }

    private var timestampLabel: some View {
        Text(timestamp, format: .dateTime.hour().minute())
            .font(theme.fonts.caption)
            .foregroundStyle(theme.colors.textTertiary.opacity(isHovered ? 0.95 : 0.55))
    }

    private var actionButtons: some View {
        HStack(spacing: 2) {
            ForEach(actions, id: \.self) { action in
                actionButton(for: action)
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
            }
        }
        .frame(width: actionBarWidth, alignment: frameAlignment)
        .contentShape(Rectangle())
        .onHover { onHoverChanged($0) }
    }

    private var actionBarWidth: CGFloat {
        guard !actions.isEmpty else { return 0 }
        return CGFloat(actions.count) * 22 + CGFloat(max(actions.count - 1, 0)) * 2
    }

    @ViewBuilder
    private func actionButton(for action: Action) -> some View {
        switch action {
        case .copy:
            CodexIconActionButton(
                systemImage: copied ? "checkmark" : "doc.on.doc",
                tint: copied ? theme.colors.success : theme.colors.textTertiary,
                help: "Copy"
            ) {
                copyToPasteboard(copyText)
                withAnimation(.snappy) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    withAnimation(.snappy) { copied = false }
                }
            }
        case .fork:
            CodexIconActionButton(
                systemImage: "arrow.triangle.branch",
                tint: theme.colors.textTertiary,
                help: "Fork from this point unavailable in this build"
            ) {}
        case .edit:
            CodexIconActionButton(
                systemImage: "square.and.pencil",
                tint: theme.colors.textTertiary,
                help: "Edit prompt"
            ) {
                onEdit?()
            }
        }
    }
}

private struct CodexIconActionButton: View {
    let systemImage: String
    let tint: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption2)
                .foregroundStyle(tint)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct CodexWorkingSpinnerBadge: View {
    @Environment(\.codexAgentTheme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(theme.colors.running)
                .frame(width: 7, height: 7)
            CodexStreamingDots()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(theme.colors.surfaceElevated.opacity(theme.effects.glassOpacity), in: Capsule())
        .overlay(Capsule().stroke(theme.colors.border, lineWidth: 1))
        .accessibilityLabel("Codex is working")
    }
}

private struct StreamingAssistantText: View {
    @Environment(\.codexAgentTheme) private var theme

    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(theme.fonts.chat)
            .foregroundStyle(theme.colors.textPrimary)
            .lineSpacing(theme.spacing.chatLineSpacing)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

public struct CodexUserMessageView: View {
    @Environment(\.codexAgentTheme) private var theme
    @Environment(\.codexTranscriptScrollActive) private var isTranscriptScrolling

    private let message: CodexChatMessage
    private let onEdit: ((String) -> Void)?
    @State private var isHovered = false
    @State private var copied = false
    @State private var hideHoverTask: Task<Void, Never>?

    public init(message: CodexChatMessage, onEdit: ((String) -> Void)? = nil) {
        self.message = message
        self.onEdit = onEdit
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 4) {
                Text(message.text)
                    .font(theme.fonts.chat)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineSpacing(theme.spacing.chatLineSpacing)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(theme.colors.userBubble, in: RoundedRectangle(cornerRadius: theme.radii.bubble, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.radii.bubble, style: .continuous)
                            .stroke(theme.colors.userBubbleStroke, lineWidth: 1)
                    )

                CodexMessageMetaFooter(
                    timestamp: message.createdAt,
                    alignment: .trailing,
                    actions: [.copy, .edit],
                    isHovered: isHovered,
                    copied: $copied,
                    copyText: message.text,
                    onEdit: onEdit.map { handler in { handler(message.text) } },
                    onHoverChanged: { updateHover($0) }
                )
            }
            .frame(maxWidth: theme.spacing.userBubbleMaxWidth, alignment: .trailing)
            .contentShape(Rectangle())
            .onHover { updateHover($0) }
        }
    }

    private func updateHover(_ hovering: Bool) {
        CodexMessageHoverReveal.reveal(
            $isHovered,
            hideTask: $hideHoverTask,
            hovering: hovering,
            scrollActive: isTranscriptScrolling
        )
    }
}

public struct CodexSystemMessageView: View {
    @Environment(\.codexAgentTheme) private var theme

    private let text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        HStack {
            Spacer()
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(theme.fonts.label)
                .foregroundStyle(theme.colors.warning)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(theme.colors.warning.opacity(0.12), in: Capsule())
            Spacer()
        }
    }
}

public struct CodexStreamingDots: View {
    @Environment(\.codexAgentTheme) private var theme

    public init() {}

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(theme.colors.accent)
                    .frame(width: 4, height: 4)
                    .opacity(index == 0 ? 0.85 : 0.45)
            }
        }
    }
}

public struct CodexThinkingShimmer: View {
    @Environment(\.codexAgentTheme) private var theme

    public init() {}

    public var body: some View {
        RoundedRectangle(cornerRadius: theme.radii.small)
            .fill(
                LinearGradient(
                    colors: [theme.colors.textSecondary.opacity(0.18), theme.colors.textSecondary.opacity(0.35), theme.colors.textSecondary.opacity(0.18)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: 180, height: 12)
    }
}

public struct CodexEmptyTranscriptView: View {
    @Environment(\.codexAgentTheme) private var theme

    private let prompts: [CodexPromptSuggestion]
    private let onSelectPrompt: (String) -> Void

    public init(
        prompts: [CodexPromptSuggestion] = Self.defaultPrompts,
        onSelectPrompt: @escaping (String) -> Void
    ) {
        self.prompts = prompts
        self.onSelectPrompt = onSelectPrompt
    }

    public var body: some View {
        VStack(spacing: 18) {
            Text("What should we work on?")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.colors.textPrimary)

            VStack(spacing: 8) {
                ForEach(prompts) { suggestion in
                    Button {
                        onSelectPrompt(suggestion.prompt)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: suggestion.systemImage)
                                .font(theme.fonts.chat)
                                .foregroundStyle(theme.colors.accent)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(suggestion.prompt)
                                    .font(theme.fonts.chat)
                                    .foregroundStyle(theme.colors.textPrimary)
                                    .multilineTextAlignment(.leading)
                                if let detail = suggestion.detail {
                                    Text(detail)
                                        .font(theme.fonts.caption)
                                        .foregroundStyle(theme.colors.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.left")
                                .font(theme.fonts.caption)
                                .foregroundStyle(theme.colors.textTertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .frame(maxWidth: 420, alignment: .leading)
                        .codexGlass(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous), interactive: true)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    public static let defaultPrompts = [
        CodexPromptSuggestion(systemImage: "ladybug", prompt: "Debug an issue"),
        CodexPromptSuggestion(systemImage: "list.bullet.clipboard", prompt: "Plan implementation"),
        CodexPromptSuggestion(systemImage: "arrow.triangle.pull", prompt: "Review a PR"),
        CodexPromptSuggestion(systemImage: "app.connected.to.app.below.fill", prompt: "Connect your favorite apps to Codex")
    ]
}
