import CodexCore
import SwiftUI

struct CodexWorkGroupViewV2: View {
    @Environment(\.codexAgentTheme) private var theme
    let group: CodexWorkGroupV2
    let onOpenSubagent: (String) -> Void
    @State private var isExpanded = false

    init(group: CodexWorkGroupV2, onOpenSubagent: @escaping (String) -> Void = { _ in }) {
        self.group = group
        self.onOpenSubagent = onOpenSubagent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(.snappy(duration: theme.animations.snappyDuration)) {
                    isExpanded.toggle()
                }
            } label: {
                CodexInlineActivityViewV2(activity: .init(
                    id: group.id,
                    label: CodexWorkGroupPresentationV2.header(group),
                    systemImage: CodexWorkGroupPresentationV2.systemImage(rows: group.rows),
                    status: CodexWorkGroupPresentationV2.status(
                        rows: group.rows,
                        isLive: group.isLive
                    )
                ))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide activity details" : "Show activity details")

            if isExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(group.rows) {
                        CodexWorkRowViewV2(row: $0, onOpenSubagent: onOpenSubagent)
                    }
                }
                .padding(.leading, 22)
                .transition(.opacity)
            }
        }
    }
}

private struct CodexWorkRowViewV2: View {
    @Environment(\.codexAgentTheme) private var theme
    let row: CodexWorkRowV2
    let onOpenSubagent: (String) -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                if let threadID = subagentThreadID { onOpenSubagent(threadID) }
                else if hasDetail { isExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(codexStatusGlyphV2(status)).foregroundStyle(statusColor)
                    label
                    if let durationMs { Text(CodexWorkBlockViewV2.duration(durationMs)).font(theme.fonts.micro) }
                    if case .command(let value) = row {
                        Text(value.executionStateLabel)
                            .font(theme.fonts.micro)
                            .foregroundStyle(statusColor)
                    }
                    if hasDetail {
                        Image(systemName: "chevron.right")
                            .font(theme.fonts.micro)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(theme.colors.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(hoverDetail ?? rowLabel)
            if isExpanded {
                expandedContent
            }
        }
    }

    @ViewBuilder private var expandedContent: some View {
        if case .fileChange(let value) = row {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(value.preparedChanges, id: \.sourceIndex) { prepared in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(prepared.path)
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !prepared.displayLines.isEmpty {
                            Text(
                                prepared.displayLines.lazy.map(\.text)
                                    .joined(separator: "\n")
                            )
                            .font(theme.fonts.code)
                            .foregroundStyle(theme.colors.textSecondary)
                            .textSelection(.enabled)
                        }
                    }
                }
                if value.omittedPreparedFileCount > 0 {
                    Text("… \(value.omittedPreparedFileCount) more files not shown")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                }
            }
            .padding(.leading, 18)
        } else if let detail = expandedDetail {
            Text(ANSITerminalStyle.makeAttributedString(from: ANSIParser().parse(detail)))
                .font(theme.fonts.code)
                .foregroundStyle(theme.colors.textSecondary)
                .textSelection(.enabled)
                .padding(.leading, 18)
        }
    }

    @ViewBuilder private var label: some View {
        switch row {
        case .command(let value):
            Text(value.label.codexDisplayPrefix(limit: 280))
                .font(value.action == .run ? theme.fonts.code : theme.fonts.caption)
            .lineLimit(1)
            .truncationMode(.middle)
        default: Text(rowLabel).font(theme.fonts.caption).lineLimit(2)
        }
    }

    private var rowLabel: String {
        switch row {
        case .command(let value): return value.label.codexDisplayPrefix(limit: 280)
        case .fileChange(let value):
            let paths = value.changes.isEmpty
                ? Array(value.files.prefix(3))
                : value.changes.prefix(3).map(\.displayPath)
            let visible = paths.joined(separator: " · ")
            let remainder = max(0, value.fileCount - 3)
            return remainder == 0 ? "Edited \(visible)" : "Edited \(visible) · +\(remainder) more"
        case .mcpToolCall(let value):
            if let error = value.errorFirstLine, !error.isEmpty { return "Called \(value.appName.isEmpty ? value.server : value.appName) · \(value.tool) — \(error)" }
            return "Called \(value.appName.isEmpty ? value.server : value.appName) · \(value.tool)"
        case .webSearch(let value): return "Searched \(value.query)"
        case .collabAgent(let value): return value.label
        case .other(let value): return value.label
        }
    }

    private var status: CodexWorkItemStatusV2 {
        switch row {
        case .command(let v): v.status; case .fileChange(let v): v.status; case .mcpToolCall(let v): v.status
        case .webSearch(let v): v.status; case .collabAgent(let v): v.status; case .other(let v): v.status
        }
    }

    private var durationMs: Int? {
        switch row {
        case .command(let v): v.durationMs; case .fileChange(let v): v.durationMs; case .mcpToolCall(let v): v.durationMs
        default: nil
        }
    }

    private var hasDetail: Bool {
        switch row {
        case .command(let value):
            value.output?.isEmpty == false
        case .fileChange(let value):
            value.hasPreparedDetail
        case .mcpToolCall(let value):
            value.arguments != nil || value.result != nil
        case .collabAgent(let value):
            (value.action == .waited || value.action == .sentInput)
                && (value.instructions?.isEmpty == false || !value.agentMessages.isEmpty)
        default:
            false
        }
    }

    private var expandedDetail: String? {
        switch row {
        case .command(let v): return v.output?.nilIfEmpty?.codexDisplayPrefix(limit: 20_000)
        case .mcpToolCall(let v):
            return CodexMCPContentPresentationV2.toolDetail(
                arguments: v.arguments,
                blocks: v.contentBlocks
            )
        case .collabAgent(let value):
            guard value.action == .waited || value.action == .sentInput else { return nil }
            let ordered = value.orderedMessageAgentNames
            let replies = ordered.compactMap { agent in
                value.agentMessages[agent].map { "\(agent)\n\($0)" }
            }.joined(separator: "\n\n")
            let parts = [value.action == .sentInput ? value.instructions?.nilIfEmpty : nil, replies.nilIfEmpty].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        default: return nil
        }
    }

    private var hoverDetail: String? {
        guard case .collabAgent = row else { return nil }
        return expandedDetail?.codexDisplayPrefix(limit: 4_000)
    }

    private var subagentThreadID: String? {
        guard case .collabAgent(let value) = row else { return nil }
        return value.agentThreadIDs.first
    }

    private var statusColor: Color {
        switch status {
        case .inProgress: theme.colors.running
        case .completed: theme.colors.success
        case .failed: theme.colors.danger
        case .declined, .unknown: theme.colors.warning
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }

    func codexDisplayPrefix(limit: Int) -> String {
        guard let boundary = index(startIndex, offsetBy: limit, limitedBy: endIndex), boundary != endIndex else { return self }
        return String(self[..<boundary]) + "\n… Output truncated for display"
    }
}
