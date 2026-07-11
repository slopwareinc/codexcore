import SwiftUI

struct CodexWorkGroupViewV2: View {
    @Environment(\.codexAgentTheme) private var theme
    let group: CodexWorkGroupV2

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(group.header)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(group.rows) { CodexWorkRowViewV2(row: $0) }
            }
            .padding(.leading, 12)
        }
    }
}

private struct CodexWorkRowViewV2: View {
    @Environment(\.codexAgentTheme) private var theme
    let row: CodexWorkRowV2
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { if detail != nil { isExpanded.toggle() } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(codexStatusGlyphV2(status)).foregroundStyle(statusColor)
                    label
                    if let durationMs { Text(CodexWorkBlockViewV2.duration(durationMs)).font(theme.fonts.micro) }
                    if detail != nil {
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
            if isExpanded, let detail {
                Text(detail)
                    .font(theme.fonts.code)
                    .foregroundStyle(theme.colors.textSecondary)
                    .textSelection(.enabled)
                    .padding(.leading, 18)
            }
        }
    }

    @ViewBuilder private var label: some View {
        switch row {
        case .command(let value):
            HStack(spacing: 3) {
                Text(value.status == .inProgress ? "Running" : "Ran").font(theme.fonts.caption)
                Text(value.command).font(theme.fonts.code)
            }
            .lineLimit(1)
            .truncationMode(.middle)
        default: Text(rowLabel).font(theme.fonts.caption).lineLimit(2)
        }
    }

    private var rowLabel: String {
        switch row {
        case .command(let value): return value.label
        case .fileChange(let value): return "Edited \(value.files.joined(separator: " · "))"
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

    private var detail: String? {
        switch row {
        case .command(let v): return v.output?.nilIfEmpty
        case .fileChange(let v): return v.diff?.nilIfEmpty
        case .mcpToolCall(let v):
            let parts = [(v.arguments.map { "Arguments\n\($0.description)" }), (v.result.map { "Result\n\($0.description)" })].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        case .collabAgent(let value):
            guard value.action == .waited || value.action == .sentInput else { return nil }
            let ordered = value.agentNames.filter { value.agentMessages[$0] != nil }
                + value.agentMessages.keys.filter { !value.agentNames.contains($0) }.sorted()
            let replies = ordered.compactMap { agent in
                value.agentMessages[agent].map { "\(agent)\n\($0)" }
            }.joined(separator: "\n\n")
            let parts = [value.action == .sentInput ? value.instructions?.nilIfEmpty : nil, replies.nilIfEmpty].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        default: return nil
        }
    }

    private var statusColor: Color {
        switch status { case .inProgress: theme.colors.running; case .completed: theme.colors.success; case .failed: theme.colors.danger }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
