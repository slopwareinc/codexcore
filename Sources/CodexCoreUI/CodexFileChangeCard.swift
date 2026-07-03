import Foundation
import SwiftUI
import CodexCore

public struct CodexFileChangeUndoKey: EnvironmentKey {
    public static let defaultValue: (@Sendable (CodexChatMessage.FileChange) -> Void)? = nil
}

public struct CodexFileChangeReviewKey: EnvironmentKey {
    public static let defaultValue: (@Sendable (CodexChatMessage.FileChange) -> Void)? = nil
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
    private let facts: CodexFileChangeFacts

    @State private var expanded = false
    @State private var copied = false
    @State private var wrapsDiff = false

    public init(
        change: CodexChatMessage.FileChange,
        onReview: ((CodexChatMessage.FileChange) -> Void)? = nil
    ) {
        self.change = change
        self.onReview = onReview
        self.facts = CodexFileChangeFacts(change: change)
    }

    private var reviewAction: ((CodexChatMessage.FileChange) -> Void)? {
        onReview ?? reviewHandler
    }

    public var body: some View {
        CodexCollapsibleCard(
            isExpanded: $expanded,
            background: theme.colors.surface.opacity(theme.effects.glassOpacity),
            border: theme.colors.border.opacity(0.74),
            maxWidth: theme.spacing.cardMaxWidth
        ) { isExpanded, toggle in
            Button {
                toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: change.isStreaming ? "square.and.pencil" : "doc.text")
                        .font(theme.fonts.caption)
                        .foregroundStyle(change.isStreaming ? theme.colors.running : theme.colors.textTertiary)
                        .frame(width: 16, height: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(change.displayPath)
                            .font(theme.fonts.code)
                            .foregroundStyle(theme.colors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(kindLabel)
                            .font(theme.fonts.micro)
                            .foregroundStyle(theme.colors.textTertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if facts.hasDiff {
                        HStack(spacing: 4) {
                            Text("+\(facts.addedLineCount)")
                                .foregroundStyle(theme.colors.success)
                            Text("−\(facts.removedLineCount)")
                                .foregroundStyle(theme.colors.danger)
                        }
                        .font(theme.fonts.micro)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(theme.colors.surfaceElevated.opacity(0.32), in: Capsule())
                    }

                    CodexFileChangeStatusChip(change: change)

                    if let undoHandler {
                        CodexFileChangeActionButton(title: "Undo", systemImage: "arrow.uturn.backward") {
                            undoHandler(change)
                        }
                    }
                    CodexFileChangeActionButton(title: "Review", systemImage: "eye") {
                        toggle()
                        reviewAction?(change)
                    }

                    Image(systemName: "chevron.down")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(theme.colors.surfaceElevated.opacity(0.28))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } body: {
            diffBody
            .frame(maxHeight: 260)
            .background(theme.colors.codeBackground)

            HStack(spacing: 10) {
                Text(diffSummary)
                    .font(theme.fonts.micro)
                    .foregroundStyle(theme.colors.codeFaint)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    wrapsDiff.toggle()
                } label: {
                    Image(systemName: wrapsDiff ? "text.line.first.and.arrowtriangle.forward" : "text.alignleft")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.codeFaint)
                }
                .buttonStyle(.plain)
                .help(wrapsDiff ? "Disable wrapping" : "Wrap diff")
                if facts.hasDiff {
                    CodexCopyButton(copied: $copied, copyText: change.diff)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(theme.colors.codeHeader)
        }
    }

    private var hasDiff: Bool {
        facts.hasDiff
    }

    @ViewBuilder
    private var diffBody: some View {
        ScrollView(wrapsDiff ? .vertical : .horizontal, showsIndicators: wrapsDiff) {
            Text(CodexFileChangeDiffCache.attributedString(for: change.diff, theme: theme))
                .font(theme.fonts.code)
                .textSelection(.enabled)
                .frame(maxWidth: wrapsDiff ? .infinity : nil, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
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
        if facts.changedFileCount > 1 {
            filePart = "\(facts.changedFileCount) files"
        } else {
            filePart = "1 file"
        }
        return "\(filePart)  +\(facts.addedLineCount) -\(facts.removedLineCount)"
    }
}

private struct CodexFileChangeFacts: Equatable {
    var hasDiff: Bool
    var changedFileCount: Int
    var addedLineCount: Int
    var removedLineCount: Int

    init(change: CodexChatMessage.FileChange) {
        hasDiff = !change.diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        guard hasDiff else {
            changedFileCount = change.path == nil ? 0 : 1
            addedLineCount = 0
            removedLineCount = 0
            return
        }

        var gitHeaders: Set<String> = []
        var fileHeaders: Set<String> = []
        var added = 0
        var removed = 0

        change.diff.enumerateLines { line, _ in
            if line.hasPrefix("diff --git ") {
                gitHeaders.insert(line)
            } else if line.hasPrefix("+++ ") {
                let newPath = String(line.dropFirst(4))
                if newPath != "/dev/null" {
                    fileHeaders.insert(newPath)
                }
            }

            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                added += 1
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                removed += 1
            }
        }

        let countedFiles = gitHeaders.isEmpty ? fileHeaders.count : gitHeaders.count
        changedFileCount = max(change.path == nil ? 0 : 1, countedFiles)
        addedLineCount = added
        removedLineCount = removed
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
                    .font(theme.fonts.caption)
                Text(title)
                    .font(theme.fonts.caption)
            }
            .foregroundStyle(theme.colors.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.colors.surfaceElevated.opacity(0.34), in: Capsule())
            .overlay(Capsule().stroke(theme.colors.border.opacity(0.74), lineWidth: 1))
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
        CodexStatusChip(color: color, label: label, isStreaming: change.isStreaming)
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

@MainActor
private enum CodexFileChangeDiffCache {
    final class Box: NSObject {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 128
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    static func attributedString(for diff: String, theme: CodexAgentTheme) -> AttributedString {
        let trimmed = diff.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            var fallback = AttributedString("No diff available")
            fallback.foregroundColor = theme.colors.codeFaint
            return fallback
        }

        let key = diff as NSString
        if let cached = cache.object(forKey: key) {
            return cached.value
        }

        var result = AttributedString()
        for line in diff.components(separatedBy: "\n") {
            var lineText = AttributedString(line.isEmpty ? " \n" : "\(line)\n")
            lineText.foregroundColor = lineColor(line, theme: theme)
            if let background = lineBackground(line, theme: theme) {
                lineText.backgroundColor = background
            }
            result.append(lineText)
        }
        cache.setObject(Box(result), forKey: key, cost: diff.utf8.count)
        return result
    }

    private static func lineColor(_ line: String, theme: CodexAgentTheme) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return theme.colors.success }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return theme.colors.danger }
        if line.hasPrefix("@@") { return theme.colors.accent }
        if line.hasPrefix("diff --git") || line.hasPrefix("+++") || line.hasPrefix("---") {
            return theme.colors.codeFaint
        }
        return theme.colors.codeText
    }

    private static func lineBackground(_ line: String, theme: CodexAgentTheme) -> Color? {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return theme.colors.success.opacity(0.08) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return theme.colors.danger.opacity(0.08) }
        return nil
    }
}

/// A compact structured card for app-server plan updates.
