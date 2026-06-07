import SwiftUI

public struct CodexTranscriptView<EmptyContent: View>: View {
    private let messages: [CodexChatMessage]
    private let emptyContent: EmptyContent

    public init(messages: [CodexChatMessage], @ViewBuilder emptyContent: () -> EmptyContent) {
        self.messages = messages
        self.emptyContent = emptyContent()
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if messages.isEmpty {
                    emptyContent
                        .frame(maxWidth: .infinity, minHeight: 420)
                        .padding(.horizontal, 28)
                } else {
                    LazyVStack(alignment: .leading, spacing: CodexTheme.Space.xl) {
                        ForEach(messages) { message in
                            CodexMessageRow(message: message)
                                .id(message.id)
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
            .onChange(of: messages.count) { _, _ in scroll(proxy, animated: true) }
            .onChange(of: messages.last?.text) { _, _ in scroll(proxy, animated: false) }
        }
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

public struct CodexMessageRow: View {
    private let message: CodexChatMessage

    public init(message: CodexChatMessage) {
        self.message = message
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
        case .assistant:
            CodexAgentRow {
                CodexAssistantMessageView(message: message)
            }
        }
    }
}

/// Left-aligned agent row with the Codex avatar.
public struct CodexAgentRow<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CodexBrandMark(size: 28)
                .padding(.top, 2)
            content
            Spacer(minLength: 32)
        }
    }
}

public struct CodexAssistantMessageView: View {
    private let message: CodexChatMessage

    public init(message: CodexChatMessage) {
        self.message = message
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Codex")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CodexTheme.secondary)
                if message.isStreaming {
                    CodexStreamingDots()
                }
            }

            if message.text.isEmpty && message.isStreaming {
                CodexThinkingShimmer()
            } else if message.isStreaming {
                StreamingAssistantText(text: message.text)
            } else {
                CodexAssistantContentView(blocks: message.renderBlocks)
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }
}

private struct StreamingAssistantText: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 14))
            .foregroundStyle(CodexTheme.primary)
            .lineSpacing(3)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

public struct CodexUserMessageView: View {
    private let message: CodexChatMessage

    public init(message: CodexChatMessage) {
        self.message = message
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 60)
            Text(message.text)
                .font(.system(size: 14))
                .foregroundStyle(CodexTheme.primary)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(CodexTheme.userBubble, in: RoundedRectangle(cornerRadius: CodexTheme.Radius.lg, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CodexTheme.Radius.lg, style: .continuous)
                        .stroke(CodexTheme.userBubbleStroke, lineWidth: 1)
                )
                .frame(maxWidth: 560, alignment: .trailing)
        }
    }
}

public struct CodexSystemMessageView: View {
    private let text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        HStack {
            Spacer()
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(CodexTheme.warning)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(CodexTheme.warning.opacity(0.12), in: Capsule())
            Spacer()
        }
    }
}

public struct CodexStreamingDots: View {
    @State private var phase = 0.0

    public init() {}

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(CodexTheme.accent)
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
    @State private var animate = false

    public init() {}

    public var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(
                LinearGradient(
                    colors: [CodexTheme.secondary.opacity(0.18), CodexTheme.secondary.opacity(0.35), CodexTheme.secondary.opacity(0.18)],
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
        VStack(spacing: CodexTheme.Space.xl) {
            CodexBrandMark(size: 56)
                .padding(.bottom, 4)

            VStack(spacing: 6) {
                Text("Start the conversation")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(CodexTheme.primary)
                Text("Ask Codex to inspect code, explain behaviour, or make changes in this workspace.")
                    .font(.system(size: 14))
                    .foregroundStyle(CodexTheme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            VStack(spacing: 8) {
                ForEach(prompts) { suggestion in
                    Button {
                        onSelectPrompt(suggestion.prompt)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: suggestion.systemImage)
                                .font(.system(size: 13))
                                .foregroundStyle(CodexTheme.accent)
                                .frame(width: 18)
                            Text(suggestion.prompt)
                                .font(.system(size: 13))
                                .foregroundStyle(CodexTheme.primary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(CodexTheme.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .frame(maxWidth: 420, alignment: .leading)
                        .codexGlass(RoundedRectangle(cornerRadius: CodexTheme.Radius.md, style: .continuous), interactive: true)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    public static let defaultPrompts = [
        CodexPromptSuggestion(systemImage: "doc.text.magnifyingglass", prompt: "Summarize this package and point out the main extension points."),
        CodexPromptSuggestion(systemImage: "arrow.triangle.branch", prompt: "Inspect the current git diff and tell me what still needs polish."),
        CodexPromptSuggestion(systemImage: "wand.and.stars", prompt: "Find one small improvement we can make safely.")
    ]
}
