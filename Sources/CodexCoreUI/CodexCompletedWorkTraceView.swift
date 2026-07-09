import SwiftUI

/// Official-style **Worked for …** disclosure.
/// Expanded body is chronological: normal assistant prose + lean activity lines
/// (Created / Closed / commands) — not nested "Updates / Update done" cards.
public struct CodexCompletedWorkTraceView: View {
    @Environment(\.codexAgentTheme) private var theme

    private let trace: CodexCompletedWorkTrace
    @State private var isExpanded: Bool

    public init(trace: CodexCompletedWorkTrace) {
        self.trace = trace
        self._isExpanded = State(initialValue: !trace.isCollapsedByDefault)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: theme.animations.snappyDuration)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Text(trace.title)
                        .font(theme.fonts.caption)
                        .foregroundStyle(
                            trace.hasFailure
                                ? theme.colors.danger.opacity(0.9)
                                : theme.colors.textTertiary
                        )
                        .lineLimit(1)

                    Image(systemName: "chevron.right")
                        .font(theme.fonts.micro)
                        .foregroundStyle(theme.colors.textTertiary.opacity(0.75))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(displayEntries) { entry in
                        entryView(entry)
                    }
                }
            }
        }
        .frame(maxWidth: theme.spacing.cardMaxWidth, alignment: .leading)
        .accessibilityLabel(trace.title)
        .accessibilityAddTraits(.isButton)
    }

    /// Prefer chronological entries; fall back to flattened legacy groups.
    private var displayEntries: [CodexCompletedWorkTrace.Entry] {
        if !trace.entries.isEmpty { return trace.entries }
        return trace.groups.flatMap { group -> [CodexCompletedWorkTrace.Entry] in
            group.operations.map { op in
                CodexCompletedWorkTrace.Entry(
                    id: op.id,
                    kind: .activity(
                        title: op.title,
                        detail: op.detail,
                        style: style(for: group.kind)
                    ),
                    createdAt: trace.createdAt
                )
            }
        }
    }

    @ViewBuilder
    private func entryView(_ entry: CodexCompletedWorkTrace.Entry) -> some View {
        switch entry.kind {
        case .narrative(let text):
            // Same rendering path as live assistant prose — no "Update done" chrome.
            CodexAssistantContentView(
                text: text,
                isStreaming: false,
                cacheNamespace: entry.id
            )
            .frame(maxWidth: .infinity, alignment: .leading)

        case .activity(let title, let detail, let style):
            activityLine(title: title, detail: detail, style: style)
        }
    }

    private func activityLine(
        title: String,
        detail: String?,
        style: CodexCompletedWorkTrace.Entry.ActivityStyle
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if style == .createdAgents || style == .closedAgents {
                Image(systemName: "person")
                    .font(theme.fonts.micro)
                    .foregroundStyle(theme.colors.textTertiary)
            }

            Text(title)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textTertiary)
                .lineLimit(2)

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(theme.fonts.micro)
                    .foregroundStyle(theme.colors.textTertiary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }

    private func style(for kind: CodexCompletedWorkTrace.Group.Kind) -> CodexCompletedWorkTrace.Entry.ActivityStyle {
        switch kind {
        case .createdAgents: return .createdAgents
        case .closedAgents: return .closedAgents
        case .command: return .command
        case .read: return .read
        case .edit: return .edit
        case .tool: return .tool
        case .plan: return .plan
        case .reasoning: return .reasoning
        case .notice: return .notice
        case .update: return .other
        }
    }
}

private extension CodexCompletedWorkTrace {
    var hasFailure: Bool {
        if entries.contains(where: { entry in
            if case .activity(_, _, let style) = entry.kind {
                return style == .notice // soft; real failures still in groups
            }
            return false
        }) {
            // fall through
        }
        return groups.contains { group in
            group.operations.contains(where: \.isFailure)
        }
    }
}
