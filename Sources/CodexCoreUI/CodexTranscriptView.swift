import SwiftUI

public struct CodexTranscriptView<EmptyContent: View>: View {
    private let messages: [CodexChatMessage]
    private let lifecycleEvents: [CodexAgentLifecycleEvent]
    private let activeTurn: CodexActiveTurnState?
    private let emptyContent: EmptyContent

    public init(
        messages: [CodexChatMessage],
        lifecycleEvents: [CodexAgentLifecycleEvent] = [],
        activeTurn: CodexActiveTurnState? = nil,
        @ViewBuilder emptyContent: () -> EmptyContent
    ) {
        self.messages = messages
        self.lifecycleEvents = lifecycleEvents
        self.activeTurn = activeTurn
        self.emptyContent = emptyContent()
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if timelineItems.isEmpty {
                    emptyContent
                        .frame(maxWidth: .infinity, minHeight: 420)
                        .padding(.horizontal, 28)
                } else {
                    LazyVStack(alignment: .leading, spacing: CodexTheme.Space.xl) {
                        ForEach(timelineItems) { item in
                            switch item {
                            case .message(let message):
                                CodexMessageRow(message: message)
                                    .id(item.id)
                            case .assistantTurn(let messages, let lifecycleEvents):
                                CodexAssistantTurnGroupView(messages: messages, lifecycleEvents: lifecycleEvents)
                                    .id(item.id)
                            case .lifecycle(let event):
                                CodexAgentLifecycleBlock(event: event)
                                    .id(item.id)
                            }
                        }
                        if let activeTurn {
                            CodexTurnWorkingBlock(state: activeTurn)
                                .id("active-turn")
                        }
                        Color.clear.frame(height: 8).id(Self.bottomAnchor)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 24)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
            .scrollContentBackground(.hidden)
            .onChange(of: timelineItems.count) { _, _ in scroll(proxy, animated: true) }
            .onChange(of: messages.last?.text) { _, _ in scroll(proxy, animated: false) }
            .onChange(of: activeTurn != nil) { _, isActive in
                if isActive { scroll(proxy, animated: true) }
            }
        }
    }

    private enum TimelineItem: Identifiable {
        case message(CodexChatMessage)
        case assistantTurn(messages: [CodexChatMessage], lifecycleEvents: [CodexAgentLifecycleEvent])
        case lifecycle(CodexAgentLifecycleEvent)

        var id: String {
            switch self {
            case .message(let message): return "message-\(message.id.uuidString)"
            case .assistantTurn(let messages, let lifecycleEvents):
                if let message = messages.first { return "assistant-turn-\(message.id.uuidString)" }
                if let event = lifecycleEvents.first { return "assistant-turn-lifecycle-\(event.id.uuidString)" }
                return "assistant-turn-empty"
            case .lifecycle(let event): return "lifecycle-\(event.id.uuidString)"
            }
        }

        var createdAt: Date {
            switch self {
            case .message(let message): return message.createdAt
            case .assistantTurn(let messages, let lifecycleEvents):
                return [messages.first?.createdAt, lifecycleEvents.first?.createdAt]
                    .compactMap { $0 }
                    .min() ?? Date()
            case .lifecycle(let event): return event.createdAt
            }
        }
    }

    private var timelineItems: [TimelineItem] {
        compactAssistantTurns(
            (messages.map(TimelineItem.message) + lifecycleEvents.map(TimelineItem.lifecycle))
            .sorted { lhs, rhs in lhs.createdAt < rhs.createdAt }
        )
    }

    private func compactAssistantTurns(_ items: [TimelineItem]) -> [TimelineItem] {
        var compacted: [TimelineItem] = []
        var pendingAssistantMessages: [CodexChatMessage] = []
        var pendingLifecycleEvents: [CodexAgentLifecycleEvent] = []

        func flushPending() {
            guard !pendingAssistantMessages.isEmpty || !pendingLifecycleEvents.isEmpty else { return }
            compacted.append(.assistantTurn(messages: pendingAssistantMessages, lifecycleEvents: pendingLifecycleEvents))
            pendingAssistantMessages = []
            pendingLifecycleEvents = []
        }

        for item in items {
            switch item {
            case .message(let message) where message.role == .assistant:
                pendingAssistantMessages.append(message)
            case .lifecycle(let event):
                pendingLifecycleEvents.append(event)
            default:
                flushPending()
                compacted.append(item)
            }
        }

        flushPending()
        return compacted
    }

    private static var bottomAnchor: String { "transcript-bottom" }

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
                    withAnimation(.snappy(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(alignment: .top, spacing: 9) {
                        statusIcon
                            .frame(width: 16, height: 16)
                            .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) {
                                Text(event.title)
                                    .font(theme.fonts.label)
                                    .foregroundStyle(theme.colors.textSecondary)
                                    .lineLimit(1)
                                if !event.agentNames.isEmpty {
                                    Text(agentCountLabel)
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(theme.colors.textTertiary)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(theme.colors.surfaceElevated.opacity(0.64), in: Capsule())
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
                            .font(.system(size: 10, weight: .bold))
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
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if !event.agentNames.isEmpty {
                            HStack(spacing: 7) {
                                ForEach(event.agentNames, id: \.self) { name in
                                    HStack(spacing: 5) {
                                        Image(systemName: "person.crop.circle.badge.checkmark")
                                            .font(.system(size: 10, weight: .semibold))
                                        Text(name)
                                            .font(.system(size: 11.5, weight: .medium))
                                    }
                                    .foregroundStyle(theme.colors.textSecondary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(theme.colors.surfaceElevated.opacity(0.72), in: Capsule())
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
            .background(theme.colors.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                    .stroke(theme.colors.border, lineWidth: 1)
            )
            .frame(maxWidth: 640, alignment: .leading)
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
            ProgressView()
                .controlSize(.mini)
                .tint(theme.colors.running)
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

    public init(message: CodexChatMessage, assistantName: String = "Codex") {
        self.message = message
        self.assistantName = assistantName
    }

    public var body: some View {
        switch message.role {
        case .system:
            CodexSystemMessageView(text: message.text)
        case .user:
            CodexUserMessageView(message: message)
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
                CodexAgentRow {
                    CodexNoticeCard(notice: notice)
                }
            }
        case .assistant:
            CodexAgentRow {
                CodexAssistantMessageView(message: message, assistantName: assistantName)
            }
        }
    }
}

public struct CodexAssistantTurnGroupView: View {
    @Environment(\.codexAgentTheme) private var theme

    private let messages: [CodexChatMessage]
    private let lifecycleEvents: [CodexAgentLifecycleEvent]

    public init(messages: [CodexChatMessage], lifecycleEvents: [CodexAgentLifecycleEvent] = []) {
        self.messages = messages
        self.lifecycleEvents = lifecycleEvents
    }

    public var body: some View {
        CodexAgentRow {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Codex")
                        .font(theme.fonts.label)
                        .foregroundStyle(theme.colors.textSecondary)
                }

                ForEach(textStreamMessages) { message in
                    assistantContent(message)
                }

                if !lifecycleEvents.isEmpty {
                    CodexSubagentRunInlineView(events: lifecycleEvents)
                }

                if let primaryMessage {
                    assistantContent(primaryMessage)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
        }
    }

    private var primaryMessage: CodexChatMessage? {
        messages.last(where: { $0.detail == "final_answer" }) ?? messages.last
    }

    private var textStreamMessages: [CodexChatMessage] {
        guard let primaryID = primaryMessage?.id else { return messages }
        return messages.filter { $0.id != primaryID }
    }

    @ViewBuilder
    private func assistantContent(_ message: CodexChatMessage) -> some View {
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
            CodexAssistantContentView(blocks: message.renderBlocks)
        }
    }

}

/// Left-aligned agent row with the Codex avatar.
public struct CodexAgentRow<Content: View>: View {
    @Environment(\.codexAgentTheme) private var theme

    private let content: Content
    private let showAvatar: Bool

    public init(showAvatar: Bool = true, @ViewBuilder content: () -> Content) {
        self.showAvatar = showAvatar
        self.content = content()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showAvatar {
                CodexBrandMark(size: 28)
                    .padding(.top, 2)
            } else {
                Circle()
                    .fill(theme.colors.surfaceElevated)
                    .frame(width: 28, height: 28)
                    .overlay(Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 11)))
                    .foregroundStyle(theme.colors.textTertiary)
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

    public init(message: CodexChatMessage, assistantName: String = "Codex") {
        self.message = message
        self.assistantName = assistantName
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(assistantName)
                    .font(theme.fonts.label)
                    .foregroundStyle(theme.colors.textSecondary)
            }

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
                CodexAssistantContentView(blocks: message.renderBlocks)
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }
}

private struct CodexWorkingSpinnerBadge: View {
    @Environment(\.codexAgentTheme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            ProgressView()
                .controlSize(.mini)
                .tint(theme.colors.running)
            CodexStreamingDots()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(theme.colors.surfaceElevated.opacity(0.72), in: Capsule())
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
            .lineSpacing(3)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

public struct CodexUserMessageView: View {
    @Environment(\.codexAgentTheme) private var theme

    private let message: CodexChatMessage

    public init(message: CodexChatMessage) {
        self.message = message
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 60)
            Text(message.text)
                .font(theme.fonts.chat)
                .foregroundStyle(theme.colors.textPrimary)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(theme.colors.userBubble, in: RoundedRectangle(cornerRadius: theme.radii.bubble, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radii.bubble, style: .continuous)
                        .stroke(theme.colors.userBubbleStroke, lineWidth: 1)
                )
                .frame(maxWidth: 560, alignment: .trailing)
        }
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
                .font(.system(size: 12))
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
    @State private var phase = 0.0

    public init() {}

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(theme.colors.accent)
                    .frame(width: 4, height: 4)
                    .opacity(opacity(for: index))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: false)) {
                phase = 3
            }
        }
    }

    private func opacity(for index: Int) -> Double {
        let distance = abs(phase.truncatingRemainder(dividingBy: 3) - Double(index))
        return 0.35 + 0.65 * max(0, 1 - distance)
    }
}

public struct CodexThinkingShimmer: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var animate = false

    public init() {}

    public var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(
                LinearGradient(
                    colors: [theme.colors.textSecondary.opacity(0.18), theme.colors.textSecondary.opacity(0.35), theme.colors.textSecondary.opacity(0.18)],
                    startPoint: animate ? .leading : .init(x: -1, y: 0.5),
                    endPoint: animate ? .init(x: 2, y: 0.5) : .trailing
                )
            )
            .frame(width: 180, height: 12)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
                    animate = true
                }
            }
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
                                .font(.system(size: 13))
                                .foregroundStyle(theme.colors.accent)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(suggestion.prompt)
                                    .font(.system(size: 13, weight: .medium))
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
                                .font(.system(size: 10, weight: .semibold))
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
        CodexPromptSuggestion(systemImage: "message.badge", prompt: "Connect messaging", detail: "get context from team discussions"),
        CodexPromptSuggestion(systemImage: "envelope", prompt: "Connect email", detail: "summarize stakeholder asks"),
        CodexPromptSuggestion(systemImage: "folder.badge.plus", prompt: "Connect files", detail: "review results, research, and plans")
    ]
}
