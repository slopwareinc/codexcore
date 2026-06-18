import SwiftUI
import CodexCore

struct CodexFileChangeUndoKey: EnvironmentKey {
    static let defaultValue: (@Sendable (CodexChatMessage.FileChange) -> Void)? = nil
}

struct CodexFileChangeReviewKey: EnvironmentKey {
    static let defaultValue: (@Sendable (CodexChatMessage.FileChange) -> Void)? = nil
}

public extension EnvironmentValues {
    var codexFileChangeUndo: (@Sendable (CodexChatMessage.FileChange) -> Void)? {
        get { self[CodexFileChangeUndoKey.self] }
        set { self[CodexFileChangeUndoKey.self] = newValue }
    }

    var codexFileChangeReview: (@Sendable (CodexChatMessage.FileChange) -> Void)? {
        get { self[CodexFileChangeReviewKey.self] }
        set { self[CodexFileChangeReviewKey.self] = newValue }
    }
}

public extension View {
    /// Enables the Undo button on file-change cards in this subtree.
    func codexFileChangeUndo(_ handler: (@Sendable (CodexChatMessage.FileChange) -> Void)?) -> some View {
        environment(\.codexFileChangeUndo, handler)
    }

    /// Enables the Review button on file-change cards in this subtree.
    func codexFileChangeReview(_ handler: (@Sendable (CodexChatMessage.FileChange) -> Void)?) -> some View {
        environment(\.codexFileChangeReview, handler)
    }
}

/// A collapsible card for app-server file-change and turn-diff updates.
public struct CodexFileChangeCard: View {
    @Environment(\.codexAgentTheme) private var theme
    @Environment(\.codexFileChangeUndo) private var undoHandler
    @Environment(\.codexFileChangeReview) private var reviewHandler

    private let change: CodexChatMessage.FileChange
    private let onReview: ((CodexChatMessage.FileChange) -> Void)?

    @State private var expanded = false
    @State private var copied = false

    public init(
        change: CodexChatMessage.FileChange,
        onReview: ((CodexChatMessage.FileChange) -> Void)? = nil
    ) {
        self.change = change
        self.onReview = onReview
    }

    private var reviewAction: ((CodexChatMessage.FileChange) -> Void)? {
        onReview ?? reviewHandler
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded { diffPane }
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
                Image(systemName: "doc.text")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.colors.codeFaint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(change.displayPath)
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.colors.codeText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(kindLabel)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.colors.codeFaint)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if hasDiff {
                    HStack(spacing: 4) {
                        Text("+\(change.addedLineCount)")
                            .foregroundStyle(theme.colors.success)
                        Text("−\(change.removedLineCount)")
                            .foregroundStyle(theme.colors.danger)
                    }
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(theme.colors.surfaceElevated.opacity(0.45), in: Capsule())
                }

                CodexFileChangeStatusChip(change: change)

                if let undoHandler {
                    CodexFileChangeActionButton(title: "Undo", systemImage: "arrow.uturn.backward") {
                        undoHandler(change)
                    }
                }
                CodexFileChangeActionButton(title: "Review", systemImage: "eye") {
                    withAnimation(.snappy(duration: 0.22)) { expanded.toggle() }
                    reviewAction?(change)
                }

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

    private var diffPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(theme.colors.border).frame(height: 1)
            ScrollView(.vertical, showsIndicators: true) {
                ScrollView(.horizontal, showsIndicators: false) {
                    if hasDiff {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                                Text(line.isEmpty ? " " : line)
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .foregroundStyle(diffLineColor(line))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 0.5)
                                    .background(diffLineBackground(line))
                            }
                        }
                        .padding(.vertical, 8)
                        .textSelection(.enabled)
                    } else {
                        Text(diffText)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(theme.colors.codeFaint)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 260)

            HStack(spacing: 10) {
                Text(diffSummary)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.colors.codeFaint)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if hasDiff {
                    CodexCopyButton(copied: $copied) { copyToPasteboard(change.diff) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(theme.colors.codeHeader)
        }
    }

    private var hasDiff: Bool {
        !change.diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var diffLines: [String] {
        change.diff.components(separatedBy: "\n")
    }

    private func diffLineColor(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return theme.colors.success }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return theme.colors.danger }
        if line.hasPrefix("@@") { return theme.colors.accent }
        if line.hasPrefix("diff --git") || line.hasPrefix("+++") || line.hasPrefix("---") {
            return theme.colors.codeFaint
        }
        return theme.colors.codeText
    }

    private func diffLineBackground(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return theme.colors.success.opacity(0.10) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return theme.colors.danger.opacity(0.10) }
        return .clear
    }

    private var diffText: String {
        if hasDiff { return change.diff }
        if !change.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return change.output }
        return change.isStreaming ? "Updating files..." : "No diff available"
    }

    private var kindLabel: String {
        change.kind.replacingOccurrences(of: "_", with: " ")
    }

    private var diffSummary: String {
        let filePart: String
        if change.changedFileCount > 1 {
            filePart = "\(change.changedFileCount) files"
        } else {
            filePart = "1 file"
        }
        return "\(filePart)  +\(change.addedLineCount) -\(change.removedLineCount)"
    }
}

private struct CodexFileChangeActionButton: View {
    @Environment(\.codexAgentTheme) private var theme

    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(theme.colors.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.colors.surfaceElevated.opacity(0.55), in: Capsule())
            .overlay(Capsule().stroke(theme.colors.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

private struct CodexFileChangeStatusChip: View {
    @Environment(\.codexAgentTheme) private var theme

    let change: CodexChatMessage.FileChange

    var body: some View {
        HStack(spacing: 5) {
            if change.isStreaming {
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
        if change.isStreaming { return "editing" }
        return change.status.isEmpty ? "updated" : change.status
    }

    private var color: Color {
        if change.isStreaming { return theme.colors.running }
        if change.status.localizedCaseInsensitiveContains("fail") { return theme.colors.danger }
        return theme.colors.success
    }
}

/// A compact structured card for app-server plan updates.
