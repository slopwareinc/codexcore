import SwiftUI
import CodexCore

@MainActor
private enum CodexMessageHoverReveal {
    static let hideDelay: Duration = .milliseconds(150)

    static func reveal(
        _ isHovered: Binding<Bool>,
        hideTask: Binding<Task<Void, Never>?>,
        hovering: Bool
    ) {
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

public struct CodexTranscriptView<EmptyContent: View>: View {
    private let messages: [CodexChatMessage]
    private let transcriptID: String?
    private let lifecycleEvents: [CodexAgentLifecycleEvent]
    private let activeTurn: CodexActiveTurnState?
    private let emptyContent: EmptyContent
    private let onCloseMessage: ((UUID) -> Void)?
    private let onOpenMCPDetails: (() -> Void)?
    private let onEditUserMessage: ((String) -> Void)?
    private let topContentMargin: CGFloat
    private let bottomContentMargin: CGFloat

    @Environment(\.codexAgentTheme) private var theme
    @State private var timelineItems: [CodexTranscriptTimelineItem] = []
    @State private var messageLookup: [UUID: CodexChatMessage] = [:]
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var isPinnedToBottom = true
    @State private var visibleItemLimit = 150

    public init(
        messages: [CodexChatMessage],
        transcriptID: String? = nil,
        lifecycleEvents: [CodexAgentLifecycleEvent] = [],
        activeTurn: CodexActiveTurnState? = nil,
        onCloseMessage: ((UUID) -> Void)? = nil,
        onOpenMCPDetails: (() -> Void)? = nil,
        onEditUserMessage: ((String) -> Void)? = nil,
        topContentMargin: CGFloat = 0,
        bottomContentMargin: CGFloat = 0,
        @ViewBuilder emptyContent: () -> EmptyContent
    ) {
        self.messages = messages
        self.transcriptID = transcriptID
        self.lifecycleEvents = lifecycleEvents
        self.activeTurn = activeTurn
        self.onCloseMessage = onCloseMessage
        self.onOpenMCPDetails = onOpenMCPDetails
        self.onEditUserMessage = onEditUserMessage
        self.topContentMargin = topContentMargin
        self.bottomContentMargin = bottomContentMargin
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
        ScrollView {
            if timelineItems.isEmpty {
                emptyContent
                    .frame(maxWidth: .infinity, minHeight: 420)
                    .padding(.horizontal, 28)
                    .padding(.top, topContentMargin)
                    .padding(.bottom, bottomContentMargin)
            } else {
                LazyVStack(alignment: .leading, spacing: theme.spacing.rowGap) {
                    ForEach(visibleTimelineItems) { item in
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
                }
                .padding(.horizontal, 28)
                .padding(.top, 24 + topContentMargin)
                .padding(.bottom, 28 + bottomContentMargin)
                .frame(maxWidth: theme.spacing.transcriptOuterMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .id(transcriptID ?? "empty")
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollContentBackground(.hidden)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - Self.bottomPinTolerance
        } action: { _, pinned in
            isPinnedToBottom = pinned
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y < Self.topExpansionThreshold
        } action: { _, isNearTop in
            guard isNearTop else { return }
            expandVisibleWindow()
        }
        .overlay(alignment: .bottomTrailing) {
            jumpToBottomButton
        }
        .onChange(of: transcriptID) { _, _ in
            resetVisibleWindow()
        }
        .task(id: transcriptInput) {
            refreshTimeline(for: transcriptInput)
        }
    }

    private var visibleTimelineItems: ArraySlice<CodexTranscriptTimelineItem> {
        timelineItems.suffix(visibleItemLimit)
    }

    @ViewBuilder
    private var jumpToBottomButton: some View {
        if !isPinnedToBottom && !timelineItems.isEmpty {
            Button {
                withAnimation(.snappy(duration: theme.animations.snappyDuration)) {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            } label: {
                Image(systemName: "arrow.down")
                    .font(theme.fonts.label)
                    .foregroundStyle(theme.colors.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(theme.colors.surfaceElevated.opacity(theme.effects.glassOpacity), in: Circle())
                    .overlay(Circle().stroke(theme.colors.border, lineWidth: 1))
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
            }
            .buttonStyle(.plain)
            .help("Jump to latest")
            .padding(.trailing, 26)
            .padding(.bottom, 18 + bottomContentMargin)
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
    }

    private func expandVisibleWindow() {
        let nextLimit = min(timelineItems.count, visibleItemLimit + Self.windowChunk)
        guard nextLimit > visibleItemLimit else { return }
        visibleItemLimit = nextLimit
    }

    private func resetVisibleWindow() {
        visibleItemLimit = Self.windowChunk
        isPinnedToBottom = true
        scrollPosition = ScrollPosition(edge: .bottom)
    }

    private static var windowChunk: Int { 150 }
    private static var bottomPinTolerance: CGFloat { 80 }
    private static var topExpansionThreshold: CGFloat { 600 }
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
        switch item.kind {
        case .messageRef:
            if let message {
                CodexMessageRow(
                    message: message,
                    onCloseMessage: onCloseMessage,
                    onOpenMCPDetails: onOpenMCPDetails,
                    onEditUserMessage: onEditUserMessage
                )
            }
        case .completedWorkTrace(let trace):
            CodexAgentRow(visibility: .hidden) {
                CodexCompletedWorkTraceView(trace: trace)
            }
        case .operationAggregate(let rows):
            CodexAgentRow(visibility: .hidden) {
                CodexOperationSummaryCard(rows: rows)
            }
        case .fileChangeAggregate(let changes):
            CodexAgentRow {
                CodexAggregateFileChangeCard(changes: changes)
            }
        case .assistantLifecycle(let events):
            CodexAgentRow(visibility: .hidden) {
                CodexSubagentRunInlineView(events: events)
            }
        case .assistantBlock(let block):
            CodexAgentRow(visibility: .hidden) {
                CodexBlockView(block: block)
                    .equatable()
            }
        case .assistantStreamingWorking(let text, let isEmpty):
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
            hovering: hovering
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
            hovering: hovering
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
