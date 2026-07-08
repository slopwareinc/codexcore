import SwiftUI
import CodexCore

@MainActor
enum CodexMessageHoverReveal {
    static let showDelay: Duration = .milliseconds(90)
    static let hideDelay: Duration = .milliseconds(150)

    static func reveal(
        _ isHovered: Binding<Bool>,
        hoverTask: Binding<Task<Void, Never>?>,
        hovering: Bool
    ) {
        hoverTask.wrappedValue?.cancel()
        hoverTask.wrappedValue = Task {
            try? await Task.sleep(for: hovering ? showDelay : hideDelay)
            guard !Task.isCancelled else { return }
            isHovered.wrappedValue = hovering
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
    private let toolCallRenderer: CodexTranscriptToolCallRenderer?
    private let contentHorizontalOffset: CGFloat
    private let topContentMargin: CGFloat
    private let bottomContentMargin: CGFloat

    @Environment(\.codexAgentTheme) private var theme
    @State private var timelineItems: [CodexTranscriptTimelineItem] = []
    @State private var messageLookup: [UUID: CodexChatMessage] = [:]
    // The live scroll offset is owned by CodexTranscriptScrollContainer, not
    // here. `.scrollPosition(_:)` is a two-way binding that SwiftUI writes back
    // on every scroll frame; keeping it out of the view that builds the row
    // list stops the whole transcript body from re-evaluating mid-scroll (which
    // is what starved the NSScroller repaint and made the thumb lag/skip).
    // We only ever *command* scrolls, via a discrete token'd command.
    @State private var scrollCommand: CodexTranscriptScrollCommand?
    @State private var scrollCommandToken = 0
    @State private var scrollMemory = CodexTranscriptScrollMemory()
    @State private var isPinnedToBottom = true
    @State private var windowState = CodexTranscriptWindowState()

    public init(
        messages: [CodexChatMessage],
        transcriptID: String? = nil,
        lifecycleEvents: [CodexAgentLifecycleEvent] = [],
        activeTurn: CodexActiveTurnState? = nil,
        onCloseMessage: ((UUID) -> Void)? = nil,
        onOpenMCPDetails: (() -> Void)? = nil,
        onEditUserMessage: ((String) -> Void)? = nil,
        toolCallRenderer: CodexTranscriptToolCallRenderer? = nil,
        contentHorizontalOffset: CGFloat = 0,
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
        self.toolCallRenderer = toolCallRenderer
        self.contentHorizontalOffset = contentHorizontalOffset
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
        CodexTranscriptScrollContainer(
            command: scrollCommand,
            onSnapshot: { snapshot in updateScrollSnapshot(snapshot) }
        ) {
            scrollContent
        }
        .overlay(alignment: .bottomTrailing) {
            jumpToBottomButton
        }
        .onChange(of: transcriptID) { oldID, newID in
            restoreVisibleWindow(from: oldID, to: newID)
        }
        .task(id: transcriptInput) {
            refreshTimeline(for: transcriptInput)
        }
    }

    @ViewBuilder
    private var scrollContent: some View {
        if timelineItems.isEmpty {
            emptyContent
                .padding(.horizontal, 28)
                .padding(.top, topContentMargin)
                .padding(.bottom, bottomContentMargin)
                // Cap to the transcript column and center it. Content that
                // fills the width (loading skeleton) stays left-aligned like
                // messages; intrinsically-narrow content (the prompt hero)
                // centers within the column.
                .frame(maxWidth: theme.spacing.transcriptOuterMaxWidth)
                .frame(maxWidth: .infinity, minHeight: 420)
                .offset(x: contentHorizontalOffset)
        } else {
            LazyVStack(alignment: .leading, spacing: theme.spacing.rowGap) {
                ForEach(visibleTimelineItems) { item in
                    CodexTranscriptTimelineRow(
                        item: item,
                        message: item.messageID.flatMap { messageLookup[$0] },
                        onCloseMessage: onCloseMessage,
                        onOpenMCPDetails: onOpenMCPDetails,
                        onEditUserMessage: onEditUserMessage,
                        toolCallRenderer: toolCallRenderer
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
            .offset(x: contentHorizontalOffset)
        }
    }

    private var visibleTimelineItems: ArraySlice<CodexTranscriptTimelineItem> {
        timelineItems.suffix(windowState.visibleItemLimit)
    }

    @ViewBuilder
    private var jumpToBottomButton: some View {
        if !isPinnedToBottom && !timelineItems.isEmpty {
            Button {
                withAnimation(.snappy(duration: theme.animations.snappyDuration)) {
                    scrollToBottom()
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

    private func prefetchOlderItems() {
        if windowState.prefetchOlderItems(totalItemCount: timelineItems.count) {
            scrollMemory.windowStates[scrollStateKey(for: transcriptID)] = windowState
        }
    }

    private func restoreVisibleWindow(from oldID: String?, to newID: String?) {
        scrollMemory.windowStates[scrollStateKey(for: oldID)] = windowState
        let newKey = scrollStateKey(for: newID)
        windowState = scrollMemory.windowStates[newKey] ?? CodexTranscriptWindowState()
        restoreScrollPosition(forKey: newKey)
    }

    private func updateScrollSnapshot(_ snapshot: CodexTranscriptScrollSnapshot) {
        let key = scrollStateKey(for: transcriptID)
        scrollMemory.snapshots[key] = snapshot
        if isPinnedToBottom != snapshot.isPinnedToBottom {
            isPinnedToBottom = snapshot.isPinnedToBottom
        }
        guard scrollMemory.topPrefetchGate.shouldPrefetch(key: key, isNearTop: snapshot.isNearTop) else {
            return
        }
        prefetchOlderItems()
    }

    private func restoreScrollPosition(forKey key: String) {
        guard let snapshot = scrollMemory.snapshots[key] else {
            issueScrollCommand(.bottom)
            isPinnedToBottom = true
            return
        }

        isPinnedToBottom = snapshot.isPinnedToBottom
        if snapshot.isPinnedToBottom {
            issueScrollCommand(.bottom)
        } else {
            issueScrollCommand(.offset(snapshot.restoredContentOffsetY))
        }
    }

    private func scrollToBottom() {
        issueScrollCommand(.bottom)
    }

    private func issueScrollCommand(_ target: CodexTranscriptScrollCommand.Target) {
        scrollCommandToken += 1
        scrollCommand = CodexTranscriptScrollCommand(token: scrollCommandToken, target: target)
    }

    private func scrollStateKey(for transcriptID: String?) -> String {
        transcriptID?.nilIfBlank ?? "__codex_empty_transcript__"
    }

    private static var bottomPinTolerance: CGFloat { 80 }
}

struct CodexTranscriptScrollCommand: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case bottom
        case offset(CGFloat)
    }

    /// Monotonic token so repeated identical targets (e.g. two "scroll to
    /// bottom" taps) still register as a distinct command via `.onChange`.
    let token: Int
    let target: Target
}

/// Owns the live scroll offset in isolation. `.scrollPosition(_:)` writes the
/// current offset back into its binding every frame while the user drags; by
/// hosting that `@State` here — away from the view that builds the row list —
/// only this lightweight container re-evaluates per frame, so the main thread
/// stays free for the NSScroller repaint. The parent drives scrolls through the
/// discrete `command` value instead of a two-way position binding.
private struct CodexTranscriptScrollContainer<Content: View>: View {
    let command: CodexTranscriptScrollCommand?
    let onSnapshot: (CodexTranscriptScrollSnapshot) -> Void
    @ViewBuilder let content: Content

    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    var body: some View {
        ScrollView {
            content
        }
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollContentBackground(.hidden)
        .onScrollGeometryChange(for: CodexTranscriptScrollSnapshot.self) { geometry in
            CodexTranscriptScrollSnapshot(
                contentOffsetY: geometry.contentOffset.y,
                contentHeight: geometry.contentSize.height,
                containerHeight: geometry.containerSize.height
            )
        } action: { _, snapshot in
            onSnapshot(snapshot)
        }
        .onChange(of: command) { _, newCommand in
            guard let newCommand else { return }
            apply(newCommand)
        }
    }

    private func apply(_ command: CodexTranscriptScrollCommand) {
        switch command.target {
        case .bottom:
            scrollPosition.scrollTo(edge: .bottom)
        case .offset(let y):
            var restored = ScrollPosition(edge: .top)
            restored.scrollTo(point: CGPoint(x: 0, y: y))
            scrollPosition = restored
        }
    }
}

private final class CodexTranscriptScrollMemory {
    var snapshots: [String: CodexTranscriptScrollSnapshot] = [:]
    var windowStates: [String: CodexTranscriptWindowState] = [:]
    var topPrefetchGate = CodexTranscriptTopPrefetchGate()
}

struct CodexTranscriptScrollSnapshot: Equatable, Sendable {
    var contentOffsetY: CGFloat
    var contentHeight: CGFloat
    var containerHeight: CGFloat
    var isPinnedToBottom: Bool
    var isNearTop: Bool

    init(
        contentOffsetY: CGFloat,
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        bottomPinTolerance: CGFloat = 80,
        topPrefetchThreshold: CGFloat = CodexTranscriptWindowState.topPrefetchThreshold
    ) {
        self.contentOffsetY = max(0, contentOffsetY)
        self.contentHeight = max(0, contentHeight)
        self.containerHeight = max(0, containerHeight)
        self.isPinnedToBottom = contentOffsetY + containerHeight >= contentHeight - bottomPinTolerance
        self.isNearTop = contentOffsetY < topPrefetchThreshold
    }

    var restoredContentOffsetY: CGFloat {
        min(contentOffsetY, max(0, contentHeight - containerHeight))
    }
}

struct CodexTranscriptWindowState: Equatable, Sendable {
    static let initialVisibleItemLimit = 150
    static let upwardExpansionChunk = 64
    static let topPrefetchThreshold: CGFloat = 2_400

    private(set) var visibleItemLimit: Int = Self.initialVisibleItemLimit

    static func shouldPrefetchOlderItems(contentOffsetY: CGFloat) -> Bool {
        contentOffsetY < Self.topPrefetchThreshold
    }

    mutating func prefetchOlderItemsIfNeeded(contentOffsetY: CGFloat, totalItemCount: Int) -> Bool {
        guard Self.shouldPrefetchOlderItems(contentOffsetY: contentOffsetY) else { return false }
        return prefetchOlderItems(totalItemCount: totalItemCount)
    }

    mutating func prefetchOlderItems(totalItemCount: Int) -> Bool {
        let nextLimit = min(totalItemCount, visibleItemLimit + Self.upwardExpansionChunk)
        guard nextLimit > visibleItemLimit else { return false }
        visibleItemLimit = nextLimit
        return true
    }

    mutating func reset() {
        visibleItemLimit = Self.initialVisibleItemLimit
    }
}

struct CodexTranscriptTopPrefetchGate: Equatable, Sendable {
    private var nearTopKeys: Set<String> = []

    mutating func shouldPrefetch(key: String, isNearTop: Bool) -> Bool {
        if isNearTop {
            return nearTopKeys.insert(key).inserted
        }
        nearTopKeys.remove(key)
        return false
    }
}

private struct CodexTranscriptRowRenderKey: Equatable {
    let item: CodexTranscriptTimelineItem
    let message: CodexChatMessageRenderKey?
    let hasToolCallRenderer: Bool

    init(item: CodexTranscriptTimelineItem, message: CodexChatMessage?, toolCallRenderer: CodexTranscriptToolCallRenderer?) {
        self.item = item
        self.message = message.map(CodexChatMessageRenderKey.init)
        self.hasToolCallRenderer = toolCallRenderer != nil
    }
}

private struct CodexTranscriptTimelineRow: View, Equatable {
    @Environment(\.codexAgentTheme) private var theme

    let item: CodexTranscriptTimelineItem
    let message: CodexChatMessage?
    let onCloseMessage: ((UUID) -> Void)?
    let onOpenMCPDetails: (() -> Void)?
    let onEditUserMessage: ((String) -> Void)?
    let toolCallRenderer: CodexTranscriptToolCallRenderer?
    private let renderKey: CodexTranscriptRowRenderKey

    init(
        item: CodexTranscriptTimelineItem,
        message: CodexChatMessage?,
        onCloseMessage: ((UUID) -> Void)?,
        onOpenMCPDetails: (() -> Void)?,
        onEditUserMessage: ((String) -> Void)?,
        toolCallRenderer: CodexTranscriptToolCallRenderer?
    ) {
        self.item = item
        self.message = message
        self.onCloseMessage = onCloseMessage
        self.onOpenMCPDetails = onOpenMCPDetails
        self.onEditUserMessage = onEditUserMessage
        self.toolCallRenderer = toolCallRenderer
        self.renderKey = CodexTranscriptRowRenderKey(item: item, message: message, toolCallRenderer: toolCallRenderer)
    }

    nonisolated static func == (lhs: CodexTranscriptTimelineRow, rhs: CodexTranscriptTimelineRow) -> Bool {
        lhs.renderKey == rhs.renderKey
    }

    var body: some View {
        switch item.kind {
        case .messageRef:
            if let message {
                CodexMessageRow(
                    message: message,
                    onCloseMessage: onCloseMessage,
                    onOpenMCPDetails: onOpenMCPDetails,
                    onEditUserMessage: onEditUserMessage,
                    toolCallRenderer: toolCallRenderer
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
    private let onCloseMessage: ((UUID) -> Void)?
    private let onOpenMCPDetails: (() -> Void)?
    private let onEditUserMessage: ((String) -> Void)?
    private let toolCallRenderer: CodexTranscriptToolCallRenderer?

    public init(
        message: CodexChatMessage,
        assistantName: String = "Codex",
        onCloseMessage: ((UUID) -> Void)? = nil,
        onOpenMCPDetails: (() -> Void)? = nil,
        onEditUserMessage: ((String) -> Void)? = nil,
        toolCallRenderer: CodexTranscriptToolCallRenderer? = nil
    ) {
        self.message = message
        self.onCloseMessage = onCloseMessage
        self.onOpenMCPDetails = onOpenMCPDetails
        self.onEditUserMessage = onEditUserMessage
        self.toolCallRenderer = toolCallRenderer
    }

    public var body: some View {
        switch message.role {
        case .system:
            CodexSystemMessageView(text: message.text)
                .accessibilityLabel("System message")
        case .user:
            CodexUserMessageView(message: message, onEdit: onEditUserMessage)
                .accessibilityLabel(CodexTranscriptAccessibility.userMessageLabel(prefix: String(message.text.prefix(60))))
        case .terminal:
            if let run = message.commandRun {
                CodexAgentRow {
                    CodexCommandCard(run: run)
                        .accessibilityLabel("Command: \(run.command.prefix(60))")
                }
            }
        case .fileChange:
            if let change = message.fileChange {
                CodexAgentRow {
                    CodexFileChangeCard(change: change)
                        .accessibilityLabel(CodexTranscriptAccessibility.fileChangeLabel(path: change.displayPath, lines: "+\(change.addedLineCount)/-\(change.removedLineCount)"))
                }
            }
        case .plan:
            if let plan = message.planUpdate {
                CodexAgentRow {
                    CodexPlanCard(plan: plan)
                        .accessibilityLabel(CodexTranscriptAccessibility.planUpdateLabel(detail: plan.summary))
                }
            }
        case .tool:
            if let toolCall = message.toolCall {
                CodexAgentRow {
                    if let customView = toolCallRenderer?.render(toolCall) {
                        customView
                    } else {
                        CodexToolCallCard(toolCall: toolCall)
                            .accessibilityLabel(CodexTranscriptAccessibility.toolCallLabel(name: toolCall.displayName))
                    }
                }
            }
        case .notice:
            if let notice = message.notice {
                if let model = CodexStatusPanelModel(notice: notice) {
                    CodexAgentRow {
                        CodexStatusPanelCard(model: model, onClose: closeAction)
                            .accessibilityLabel("Status: \(model.connectionLabel)")
                    }
                } else if let model = CodexMCPStatusPanelModel(notice: notice) {
                    CodexAgentRow {
                        CodexMCPStatusPanelCard(
                            model: model,
                            onClose: closeAction,
                            onOpenDetails: onOpenMCPDetails
                        )
                        .accessibilityLabel("MCP status: \(model.title)")
                    }
                } else {
                    CodexAgentRow {
                        CodexNoticeCard(notice: notice)
                            .accessibilityLabel("Notice: \(notice.title)")
                    }
                }
            }
        case .reasoning:
            if let block = message.reasoningBlock {
                CodexAgentRow {
                    CodexReasoningCard(block: block)
                        .accessibilityLabel("Reasoning step")
                }
            }
        case .assistant:
            CodexAgentRow(visibility: .hidden) {
                CodexAssistantMessageView(message: message)
                    .accessibilityLabel(CodexTranscriptAccessibility.assistantMessageLabel(prefix: String(message.text.prefix(60))))
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
    @State private var isHovered = false
    @State private var copied = false
    @State private var hoverTask: Task<Void, Never>?

    public init(message: CodexChatMessage, assistantName: String = "Codex") {
        self.message = message
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
                        onEdit: nil
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
            hoverTask: $hoverTask,
            hovering: hovering
        )
    }

    private var turnEndActions: [CodexLiveTurnModel.TurnEndAction] {
        CodexLiveTurnModel.turnEndActions(for: message)
    }

    private var turnEndFooterActions: [CodexMessageFooterAction] {
        turnEndActions.map {
            switch $0 {
            case .copy: .copy
            case .fork: .fork
            }
        }
    }
}

enum CodexMessageFooterAction: Hashable, Sendable {
    case copy
    case fork
    case edit
}

struct CodexMessageFooterChromeState: Equatable, Sendable {
    let actions: [CodexMessageFooterAction]
    let isHovered: Bool

    var visibleActions: [CodexMessageFooterAction] {
        isHovered ? actions : []
    }

    var actionBarWidth: CGFloat {
        guard !actions.isEmpty else { return 0 }
        return CGFloat(actions.count) * 22 + CGFloat(max(actions.count - 1, 0)) * 2
    }

    var timestampOpacity: Double {
        isHovered ? 0.95 : 0.55
    }
}

private struct CodexMessageMetaFooter: View {
    @Environment(\.codexAgentTheme) private var theme
    @Environment(\.codexClipboardService) private var clipboardService

    static let reservedHeight: CGFloat = 20

    let timestamp: Date
    let alignment: HorizontalAlignment
    let actions: [CodexMessageFooterAction]
    let isHovered: Bool
    @Binding var copied: Bool
    let copyText: String
    let onEdit: (() -> Void)?

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
    }

    private var chrome: CodexMessageFooterChromeState {
        CodexMessageFooterChromeState(actions: actions, isHovered: isHovered)
    }

    private var frameAlignment: Alignment {
        alignment == .trailing ? .trailing : .leading
    }

    private var timestampLabel: some View {
        Text(timestamp, format: .dateTime.hour().minute())
            .font(theme.fonts.caption)
            .foregroundStyle(theme.colors.textTertiary.opacity(chrome.timestampOpacity))
    }

    private var actionButtons: some View {
        HStack(spacing: 2) {
            ForEach(chrome.visibleActions, id: \.self) { action in
                actionButton(for: action)
            }
        }
        .frame(width: chrome.actionBarWidth, alignment: frameAlignment)
    }

    @ViewBuilder
    private func actionButton(for action: CodexMessageFooterAction) -> some View {
        switch action {
        case .copy:
            CodexIconActionButton(
                systemImage: copied ? "checkmark" : "doc.on.doc",
                tint: copied ? theme.colors.success : theme.colors.textTertiary,
                help: "Copy"
            ) {
                clipboardService.copy(copyText)
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
    @State private var hoverTask: Task<Void, Never>?

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
                    onEdit: onEdit.map { handler in { handler(message.text) } }
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
            hoverTask: $hoverTask,
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
