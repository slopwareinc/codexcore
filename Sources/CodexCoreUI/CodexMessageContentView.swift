import SwiftUI
import CodexCore

/// Renders projected assistant content blocks: prose, code blocks, and inline images.
public struct CodexAssistantContentView: View {
    @Environment(\.codexAgentTheme) private var theme

    private let blocks: [CodexBlock]
    private let cacheNamespace: String

    /// Direct-from-text initializer. Preferred for streaming
    /// assistant messages because it lets the projector reuse the
    /// previous block list and only re-parse the live tail.
    public init(text: String, isStreaming: Bool, cacheNamespace: String, previous: [CodexBlock]? = nil) {
        self.cacheNamespace = cacheNamespace
        self.blocks = CodexBlockProjector.project(
            text,
            previous: previous,
            streaming: isStreaming,
            cacheNamespace: cacheNamespace
        )
    }

    public init(projectedBlocks: [CodexBlock], cacheNamespace: String) {
        self.blocks = projectedBlocks
        self.cacheNamespace = cacheNamespace
    }

    /// Exposed so callers streaming a single assistant message can
    /// pass the previous block list back in on the next delta. This
    /// is what makes tail-only re-parsing work.
    public var projectedBlocks: [CodexBlock] { blocks }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.rowGap) {
            ForEach(blocks) { block in
                CodexBlockView(block: block)
                    .equatable()
                    .id(block.id)
            }
        }
    }
}

public struct CodexCodeBlock: View {
    @Environment(\.codexAgentTheme) private var theme

    private let language: String?
    private let code: String

    @State private var copied = false

    public init(language: String?, code: String) {
        self.language = language
        self.code = code
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.codeFaint)
                Text(displayLanguage)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.codeFaint)
                Spacer()
                CodexCopyButton(copied: $copied, copyText: code)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.colors.codeHeader)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(theme.fonts.code)
                    .foregroundStyle(theme.colors.codeText)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.colors.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
    }

    private var displayLanguage: String {
        if let language, !language.isEmpty { language } else { "code" }
    }
}

/// A collapsible terminal-style card for command execution output.
public struct CodexCommandCard: View {
    @Environment(\.codexAgentTheme) private var theme

    private let run: CodexChatMessage.CommandRun

    @State private var expanded = false
    @State private var copied = false

    public init(run: CodexChatMessage.CommandRun) {
        self.run = run
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: theme.animations.snappyDuration)) {
                    expanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Command only — no "Ran"/"Running" title chrome.
                    Text(commandText)
                        .font(theme.fonts.code)
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let meta = headerMeta {
                        Text(meta)
                            .font(theme.fonts.micro)
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(theme.fonts.micro)
                        .foregroundStyle(theme.colors.textTertiary.opacity(0.7))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(outputText)
                        .font(theme.fonts.code)
                        .foregroundStyle(hasOutput ? theme.colors.textSecondary : theme.colors.textTertiary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        if let cwd = run.cwd, !cwd.isEmpty {
                            Text(cwd)
                                .font(theme.fonts.micro)
                                .foregroundStyle(theme.colors.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        if hasOutput {
                            CodexCopyButton(copied: $copied, copyText: run.output)
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 2)
            }
        }
        .frame(maxWidth: theme.spacing.cardMaxWidth, alignment: .leading)
        .onAppear {
            if run.isStreaming { expanded = true }
        }
        .onChange(of: run.isStreaming) { _, isStreaming in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                expanded = isStreaming
            }
        }
        .accessibilityLabel(commandText)
    }

    private var commandText: String {
        let command = run.command.trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? "command" : command
    }

    private var headerMeta: String? {
        if run.isStreaming { return "…" }
        if let exit = run.exitCode {
            return exit == 0 ? "exit 0" : "exit \(exit)"
        }
        if !run.status.isEmpty { return run.status }
        return hasOutput ? outputSummary : nil
    }

    private var statusColor: Color {
        if run.isStreaming { return theme.colors.running }
        if let exit = run.exitCode, exit != 0 { return theme.colors.danger }
        if run.status.localizedCaseInsensitiveContains("fail") { return theme.colors.danger }
        return theme.colors.textTertiary
    }

    private var hasOutput: Bool {
        !run.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var outputText: String {
        if hasOutput { return run.output }
        return run.isStreaming ? "Running…" : "No output"
    }

    private var outputSummary: String {
        let lines = run.output.split(whereSeparator: \.isNewline).count
        if lines > 0 { return lines == 1 ? "1 line" : "\(lines) lines" }
        return "\(run.output.count) chars"
    }
}

/// A collapsible card for streamed model reasoning output.
public struct CodexReasoningCard: View {
    @Environment(\.codexAgentTheme) private var theme

    private let block: CodexChatMessage.ReasoningBlock

    @State private var expanded = false

    public init(block: CodexChatMessage.ReasoningBlock) {
        self.block = block
    }

    public var body: some View {
        CodexCollapsibleCard(
            isExpanded: $expanded,
            background: theme.colors.surfaceElevated.opacity(0.35),
            border: theme.colors.border.opacity(0.8),
            maxWidth: theme.spacing.cardMaxWidth
        ) { isExpanded, toggle in
            Button {
                toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "brain.head.profile")
                        .font(theme.fonts.label)
                        .foregroundStyle(theme.colors.codeFaint)

                    Text(block.title)
                        .font(theme.fonts.label)
                        .foregroundStyle(theme.colors.codeText)

                    Spacer(minLength: 8)

                    if block.isStreaming {
                        Circle()
                            .fill(theme.colors.running)
                            .frame(width: 7, height: 7)
                    } else if !isExpanded, hasText {
                        Text(previewText)
                            .font(theme.fonts.micro)
                            .foregroundStyle(theme.colors.codeFaint)
                            .lineLimit(1)
                    }

                    Image(systemName: "chevron.right")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.codeFaint)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(theme.colors.codeHeader.opacity(0.65))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } body: {
            ScrollView(.vertical, showsIndicators: true) {
                Text(displayText)
                    .font(theme.fonts.code)
                    .foregroundStyle(hasText ? theme.colors.codeText : theme.colors.codeFaint)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        }
        .onAppear {
            if block.isStreaming { expanded = true }
        }
        .onChange(of: block.isStreaming) { _, isStreaming in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                expanded = isStreaming
            }
        }
    }

    private var hasText: Bool {
        !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var displayText: String {
        if hasText { return block.text }
        return block.isStreaming ? "Thinking..." : "No reasoning captured"
    }

    private var previewText: String {
        block.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Environment hook for undoing a file change, injected once at the workspace
/// root so cards can offer Undo without threading a closure through every view.
public struct CodexPlanCard: View {
    @Environment(\.codexAgentTheme) private var theme

    private let plan: CodexChatMessage.PlanUpdate

    @State private var expanded = true
    @State private var copied = false

    public init(plan: CodexChatMessage.PlanUpdate) {
        self.plan = plan
    }

    public var body: some View {
        CodexCollapsibleCard(
            isExpanded: $expanded,
            background: theme.colors.codeBackground,
            border: theme.colors.border,
            maxWidth: theme.spacing.cardMaxWidth
        ) { isExpanded, toggle in
            Button {
                toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "checklist")
                        .font(theme.fonts.label)
                        .foregroundStyle(theme.colors.codeFaint)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Plan")
                            .font(theme.fonts.label)
                            .foregroundStyle(theme.colors.codeText)
                        Text(plan.summary)
                            .font(theme.fonts.micro)
                            .foregroundStyle(theme.colors.codeFaint)
                    }

                    Spacer(minLength: 8)

                    CodexPlanStatusChip(plan: plan)

                    Image(systemName: "chevron.right")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.codeFaint)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(theme.colors.codeHeader)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } body: {
            VStack(alignment: .leading, spacing: 10) {
                if let explanation = plan.explanation, !explanation.isEmpty {
                    Text(explanation)
                        .font(theme.fonts.chat)
                        .foregroundStyle(theme.colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if plan.steps.isEmpty {
                    Text(plan.text.isEmpty ? (plan.isStreaming ? "Planning..." : "No plan steps") : plan.text)
                        .font(theme.fonts.chat)
                        .foregroundStyle(plan.text.isEmpty ? theme.colors.textTertiary : theme.colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
                            planStepRow(step)
                        }
                    }
                }
            }
            .padding(12)

            if !plan.copyText.isEmpty {
                HStack {
                    Spacer()
                    CodexCopyButton(copied: $copied, copyText: plan.copyText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(theme.colors.codeHeader)
            }
        }
    }

    private func planStepRow(_ step: CodexChatMessage.PlanUpdate.Step) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: stepIcon(for: step))
                .font(theme.fonts.label)
                .foregroundStyle(stepColor(for: step))
                .frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.step)
                    .font(theme.fonts.chat)
                    .foregroundStyle(theme.colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(step.displayStatus)
                    .font(theme.fonts.micro)
                    .foregroundStyle(theme.colors.textTertiary)
            }
        }
    }

    private func stepIcon(for step: CodexChatMessage.PlanUpdate.Step) -> String {
        if step.isCompleted { return "checkmark.circle.fill" }
        if step.isActive { return "circle.dotted" }
        return "circle"
    }

    private func stepColor(for step: CodexChatMessage.PlanUpdate.Step) -> Color {
        if step.isCompleted { return theme.colors.success }
        if step.isActive { return theme.colors.running }
        return theme.colors.textTertiary
    }
}

private struct CodexPlanStatusChip: View {
    @Environment(\.codexAgentTheme) private var theme

    let plan: CodexChatMessage.PlanUpdate

    var body: some View {
        CodexStatusChip(color: color, label: label, isStreaming: plan.isStreaming)
    }

    private var label: String {
        if plan.isStreaming { return "planning" }
        if !plan.steps.isEmpty, plan.completedStepCount == plan.steps.count { return "complete" }
        if plan.activeStepCount > 0 { return "working" }
        return "planned"
    }

    private var color: Color {
        if plan.isStreaming || plan.activeStepCount > 0 { return theme.colors.running }
        if !plan.steps.isEmpty, plan.completedStepCount == plan.steps.count { return theme.colors.success }
        return theme.colors.textSecondary
    }
}

/// A collapsible card for MCP and dynamic tool calls.
private struct CodexCommandStatusChip: View {
    @Environment(\.codexAgentTheme) private var theme

    let run: CodexChatMessage.CommandRun

    var body: some View {
        CodexStatusChip(color: color, label: label, isStreaming: run.isStreaming)
    }

    private var label: String {
        if run.isStreaming { return "running" }
        if let exitCode = run.exitCode { return exitCode == 0 ? "exit 0" : "exit \(exitCode)" }
        return run.status
    }

    private var color: Color {
        if run.isStreaming { return theme.colors.running }
        if let exitCode = run.exitCode, exitCode != 0 { return theme.colors.danger }
        return theme.colors.success
    }
}

public struct CodexCopyButton: View {
    @Environment(\.codexAgentTheme) private var theme
    @Environment(\.codexClipboardService) private var clipboardService

    @Binding private var copied: Bool
    private let copyText: String

    public init(copied: Binding<Bool>, copyText: String) {
        self._copied = copied
        self.copyText = copyText
    }

    public var body: some View {
        Button {
            clipboardService.copy(copyText)
            withAnimation(.snappy) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.snappy) { copied = false }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(theme.fonts.caption)
                Text(copied ? "Copied" : "Copy")
                    .font(theme.fonts.caption)
            }
            .foregroundStyle(copied ? theme.colors.success : theme.colors.codeFaint)
        }
        .buttonStyle(.plain)
    }
}
