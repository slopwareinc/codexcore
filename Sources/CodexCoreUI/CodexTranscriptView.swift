import SwiftUI

public struct CodexTranscriptView<EmptyContent: View>: View {
    private let timelineItems: [CodexTranscriptTimelineItem]
    private let activeTurn: CodexActiveTurnState?
    private let emptyContent: EmptyContent

    @Environment(\.codexAgentTheme) private var theme

    public init(
        messages: [CodexChatMessage],
        lifecycleEvents: [CodexAgentLifecycleEvent] = [],
        activeTurn: CodexActiveTurnState? = nil,
        @ViewBuilder emptyContent: () -> EmptyContent
    ) {
        self.timelineItems = CodexTranscriptTimelineBuilder.build(
            messages: messages,
            lifecycleEvents: lifecycleEvents
        )
        self.activeTurn = activeTurn
        self.emptyContent = emptyContent()
    }

    public var body: some View {
        ScrollView {
            if timelineItems.isEmpty {
                emptyContent
                    .frame(maxWidth: .infinity, minHeight: 420)
                    .padding(.horizontal, 28)
            } else {
                LazyVStack(alignment: .leading, spacing: theme.spacing.rowGap) {
                    ForEach(timelineItems) { item in
                        switch item {
                        case .message(let message):
                            CodexMessageRow(message: message)
                                .id(item.id)
                        case .fileChangeAggregate(_, let changes):
                            CodexAgentRow {
                                CodexAggregateFileChangeCard(changes: changes)
                            }
                            .id(item.id)
                        case .assistantTurnHeader(_, let name):
                            CodexAgentRow(showAvatar: true) {
                                Text(name)
                                    .font(theme.fonts.label)
                                    .foregroundStyle(theme.colors.textSecondary)
                                    .padding(.bottom, 2)
                            }
                            .id(item.id)
                        case .assistantLifecycle(_, let events):
                            CodexAgentRow(visibility: .hidden) {
                                CodexSubagentRunInlineView(events: events)
                            }
                            .id(item.id)
                        case .assistantBlock(_, let block):
                            CodexAgentRow(visibility: .hidden) {
                                CodexBlockView(block: block)
                                    .equatable()
                            }
                            .id(item.id)
                        case .assistantStreamingWorking(_, let text, let isEmpty):
                            CodexAgentRow(visibility: .hidden) {
                                HStack(alignment: .bottom, spacing: 9) {
                                    if isEmpty {
                                        CodexThinkingShimmer()
                                    } else {
                                        Text(verbatim: text)
                                            .font(theme.fonts.chat)
                                            .foregroundStyle(theme.colors.textPrimary)
                                            .lineSpacing(3)
                                            .multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    CodexWorkingSpinnerBadge()
                                        .padding(.bottom, isEmpty ? 1 : 2)
                                }
                            }
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
                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 28)
                .frame(maxWidth: theme.spacing.transcriptOuterMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .scrollContentBackground(.hidden)
        .defaultScrollAnchor(.bottom)
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
        case .reasoning:
            if let block = message.reasoningBlock {
                CodexAgentRow {
                    CodexReasoningCard(block: block)
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
                    assistantContent(message, showsResponseActions: false)
                }

                if !lifecycleEvents.isEmpty {
                    CodexSubagentRunInlineView(events: lifecycleEvents)
                }

                if let primaryMessage {
                    assistantContent(primaryMessage, showsResponseActions: true)
                }
            }
            .frame(maxWidth: theme.spacing.cardMaxWidth, alignment: .leading)
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
    private func assistantContent(_ message: CodexChatMessage, showsResponseActions: Bool) -> some View {
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
            if showsResponseActions {
                let actionTitles = CodexLiveTurnModel.responseActionTitles(for: message)
                if !actionTitles.isEmpty {
                    CodexResponseActionRow(titles: actionTitles, copyText: message.text)
                }
            }
        }
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
                let actionTitles = CodexLiveTurnModel.responseActionTitles(for: message)
                if !actionTitles.isEmpty {
                    CodexResponseActionRow(titles: actionTitles, copyText: message.text)
                }
            }
        }
        .frame(maxWidth: theme.spacing.cardMaxWidth, alignment: .leading)
    }
}

private struct CodexResponseActionRow: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var copied = false

    let titles: [String]
    let copyText: String

    var body: some View {
        HStack(spacing: 12) {
            ForEach(titles, id: \.self) { title in
                if title == "Copy" {
                    CodexCopyButton(copied: $copied) {
                        copyToPasteboard(copyText)
                    }
                    .help(title)
                } else {
                    Label(title, systemImage: icon(for: title))
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .help("\(title) unavailable in this build")
                }
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(titles.joined(separator: ", "))
    }

    private func icon(for title: String) -> String {
        switch title {
        case "Good response":
            return "hand.thumbsup"
        case "Bad response":
            return "hand.thumbsdown"
        case "Fork from this point":
            return "arrow.triangle.branch"
        default:
            return "circle"
        }
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
            .lineSpacing(3)
            .multilineTextAlignment(.leading)
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
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(theme.colors.userBubble, in: RoundedRectangle(cornerRadius: theme.radii.bubble, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radii.bubble, style: .continuous)
                        .stroke(theme.colors.userBubbleStroke, lineWidth: 1)
                )
                .frame(maxWidth: theme.spacing.userBubbleMaxWidth, alignment: .trailing)
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
        RoundedRectangle(cornerRadius: theme.radii.small)
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
