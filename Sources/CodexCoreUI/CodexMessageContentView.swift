import SwiftUI
import CodexCore

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Renders parsed assistant content blocks: prose, code blocks, and inline images.
public struct CodexAssistantContentView: View {
    private let blocks: [AssistantRenderBlock]

    public init(blocks: [AssistantRenderBlock]) {
        self.blocks = blocks
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CodexTheme.Space.md) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .markdown(let markdown):
                    CodexMarkdownText(markdown)
                case .codeBlock(let language, let code):
                    CodexCodeBlock(language: language, code: code)
                case .inlineImage:
                    Label("Inline image", systemImage: "photo")
                        .font(.callout)
                        .foregroundStyle(CodexTheme.secondary)
                }
            }
        }
    }
}

/// Chat-tuned GitHub Flavored Markdown renderer.
public struct CodexMarkdownText: View {
    private let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public var body: some View {
        CodexMarkdownView(raw)
            .font(.system(size: 14))
            .foregroundStyle(CodexTheme.primary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

public struct CodexCodeBlock: View {
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
                    .foregroundStyle(CodexTheme.codeFaint)
                Text(displayLanguage)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CodexTheme.codeFaint)
                Spacer()
                CodexCopyButton(copied: $copied) { copyToPasteboard(code) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(CodexTheme.codeBGHeader)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(CodexTheme.codeText)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(CodexTheme.codeBG)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.Radius.md, style: .continuous)
                .stroke(CodexTheme.codeStroke, lineWidth: 1)
        )
    }

    private var displayLanguage: String {
        language?.isEmpty == false ? language! : "code"
    }
}

/// A collapsible terminal-style card for command execution output.
public struct CodexCommandCard: View {
    private let run: CodexChatMessage.CommandRun

    @State private var expanded = true
    @State private var copied = false

    public init(run: CodexChatMessage.CommandRun) {
        self.run = run
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded { outputPane }
        }
        .background(CodexTheme.codeBG)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.Radius.md, style: .continuous)
                .stroke(CodexTheme.codeStroke, lineWidth: 1)
        )
        .frame(maxWidth: 640, alignment: .leading)
    }

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) { expanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(CodexTheme.codeFaint)

                Text(run.command)
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(CodexTheme.codeText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                CodexCommandStatusChip(run: run)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(CodexTheme.codeFaint)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(CodexTheme.codeBGHeader)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(CodexTheme.codeStroke).frame(height: 1)
            ScrollView(.vertical, showsIndicators: true) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(outputText)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(hasOutput ? CodexTheme.codeText : CodexTheme.codeFaint)
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
                            .foregroundStyle(CodexTheme.codeFaint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    CodexCopyButton(copied: $copied) { copyToPasteboard(run.output) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(CodexTheme.codeBGHeader)
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
}

private struct CodexCommandStatusChip: View {
    let run: CodexChatMessage.CommandRun

    var body: some View {
        HStack(spacing: 5) {
            if run.isStreaming {
                ProgressView()
                    .controlSize(.mini)
                    .tint(CodexTheme.running)
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
        if run.isStreaming { return CodexTheme.running }
        if let exitCode = run.exitCode, exitCode != 0 { return CodexTheme.danger }
        return CodexTheme.success
    }
}

public struct CodexCopyButton: View {
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
            .foregroundStyle(copied ? CodexTheme.success : CodexTheme.codeFaint)
        }
        .buttonStyle(.plain)
    }
}

private func copyToPasteboard(_ text: String) {
    #if canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #elseif canImport(UIKit)
    UIPasteboard.general.string = text
    #endif
}
