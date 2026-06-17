import SwiftUI
import CodexCore

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Renders parsed assistant content blocks: prose, code blocks, and inline images.
public struct CodexAssistantContentView: View {
    @Environment(\.codexAgentTheme) private var theme

    private let blocks: [AssistantRenderBlock]

    public init(blocks: [AssistantRenderBlock]) {
        self.blocks = blocks
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.rowGap) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .markdown(let markdown):
                    CodexMarkdownText(markdown)
                case .codeBlock(let language, let code):
                    CodexCodeBlock(language: language, code: code)
                case .inlineImage:
                    Label("Inline image", systemImage: "photo")
                        .font(.callout)
                        .foregroundStyle(theme.colors.textSecondary)
                }
            }
        }
    }
}

/// Chat-tuned GitHub Flavored Markdown renderer.
public struct CodexMarkdownText: View {
    @Environment(\.codexAgentTheme) private var theme

    private let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public var body: some View {
        CodexMarkdownView(raw)
            .font(theme.fonts.chat)
            .foregroundStyle(theme.colors.textPrimary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
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
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.colors.codeFaint)
                Text(displayLanguage)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.colors.codeFaint)
                Spacer()
                CodexCopyButton(copied: $copied) { copyToPasteboard(code) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.colors.codeHeader)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(theme.colors.codeText)
                    .textSelection(.enabled)
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
        language?.isEmpty == false ? language! : "code"
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
            header
            if expanded { outputPane }
        }
        .background(theme.colors.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
        .frame(maxWidth: 640, alignment: .leading)
        .onAppear {
            if run.isStreaming { expanded = true }
        }
        .onChange(of: run.isStreaming) { _, isStreaming in
            if isStreaming { expanded = true }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) { expanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.colors.codeFaint)

                Text(run.command)
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.colors.codeText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                if !expanded && hasOutput {
                    Text(outputSummary)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.colors.codeFaint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(theme.colors.surfaceElevated.opacity(0.45), in: Capsule())
                }

                CodexCommandStatusChip(run: run)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.colors.codeFaint)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(theme.colors.codeHeader)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(theme.colors.border).frame(height: 1)
            ScrollView(.vertical, showsIndicators: true) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(outputText)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(hasOutput ? theme.colors.codeText : theme.colors.codeFaint)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: 240)

            if hasOutput {
                HStack {
                    if let cwd = run.cwd, !cwd.isEmpty {
                        Text(cwd)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(theme.colors.codeFaint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    CodexCopyButton(copied: $copied) { copyToPasteboard(run.output) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(theme.colors.codeHeader)
            }
        }
    }

    private var hasOutput: Bool {
        !run.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var outputText: String {
        if hasOutput { return run.output }
        return run.isStreaming ? "Running..." : "No output"
    }

    private var outputSummary: String {
        let lines = run.output.split(whereSeparator: \.isNewline).count
        if lines > 0 { return lines == 1 ? "1 line" : "\(lines) lines" }
        return run.output.count == 1 ? "1 char" : "\(run.output.count) chars"
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
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded { bodyContent }
        }
        .background(theme.colors.surfaceElevated.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.border.opacity(0.8), lineWidth: 1)
        )
        .frame(maxWidth: 640, alignment: .leading)
        .onAppear {
            if block.isStreaming { expanded = true }
        }
        .onChange(of: block.isStreaming) { _, isStreaming in
            if isStreaming { expanded = true }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) { expanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.colors.codeFaint)

                Text(block.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.colors.codeText)

                Spacer(minLength: 8)

                if block.isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                } else if !expanded, hasText {
                    Text(previewText)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.colors.codeFaint)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.colors.codeFaint)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(theme.colors.codeHeader.opacity(0.65))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(theme.colors.border).frame(height: 1)
            ScrollView(.vertical, showsIndicators: true) {
                Text(displayText)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(hasText ? theme.colors.codeText : theme.colors.codeFaint)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
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
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded { bodyContent }
        }
        .background(theme.colors.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
        .frame(maxWidth: 640, alignment: .leading)
    }

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) { expanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checklist")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.colors.codeFaint)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Plan")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.colors.codeText)
                    Text(plan.summary)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.colors.codeFaint)
                }

                Spacer(minLength: 8)

                CodexPlanStatusChip(plan: plan)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.colors.codeFaint)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(theme.colors.codeHeader)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(theme.colors.border).frame(height: 1)
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
                    CodexCopyButton(copied: $copied) { copyToPasteboard(plan.copyText) }
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(stepColor(for: step))
                .frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.step)
                    .font(theme.fonts.chat)
                    .foregroundStyle(theme.colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(step.displayStatus)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
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
        HStack(spacing: 5) {
            if plan.isStreaming {
                ProgressView()
                    .controlSize(.mini)
                    .tint(theme.colors.running)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(label)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.16), in: Capsule())
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
        HStack(spacing: 5) {
            if run.isStreaming {
                ProgressView()
                    .controlSize(.mini)
                    .tint(theme.colors.running)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(label)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.16), in: Capsule())
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

    @Binding private var copied: Bool
    private let action: () -> Void

    public init(copied: Binding<Bool>, action: @escaping () -> Void) {
        self._copied = copied
        self.action = action
    }

    public var body: some View {
        Button {
            action()
            withAnimation(.snappy) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.snappy) { copied = false }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                Text(copied ? "Copied" : "Copy")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(copied ? theme.colors.success : theme.colors.codeFaint)
        }
        .buttonStyle(.plain)
    }
}

func copyToPasteboard(_ text: String) {
    #if canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #elseif canImport(UIKit)
    UIPasteboard.general.string = text
    #endif
}
