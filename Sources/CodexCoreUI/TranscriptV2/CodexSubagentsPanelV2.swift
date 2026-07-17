import SwiftUI

public struct CodexSubagentsPanelV2: View {
    @Environment(\.codexAgentTheme) private var theme
    private let store: CodexSubagentStoreV2

    public init(store: CodexSubagentStoreV2) { self.store = store }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Subagents").font(theme.fonts.label)
                Spacer()
                Text("\(store.workingCount) working").font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary)
            }
            ForEach(store.agents) { agent in
                agentCard(agent).padding(.leading, CGFloat(max(0, agent.depth - 1)) * 12)
            }
        }
        .padding(12)
    }

    private func agentCard(_ agent: CodexSubagentV2) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(agent.displayName).font(theme.fonts.label)
                if let role = agent.role, !role.isEmpty {
                    Text(role).font(theme.fonts.micro).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(theme.colors.surfaceSunken, in: Capsule())
                }
                Spacer()
                CodexSubagentStopwatchV2(status: agent.status)
            }
            CodexTranscriptViewV2(transcript: agent.transcript)
                .frame(minHeight: 120, maxHeight: 300)
                .environment(\.codexAgentTheme, compactTheme)
        }
        .padding(10)
        .background(theme.colors.surface, in: RoundedRectangle(cornerRadius: theme.radii.medium))
        .overlay(RoundedRectangle(cornerRadius: theme.radii.medium).stroke(theme.colors.border))
    }

    private var compactTheme: CodexAgentTheme {
        var value = theme
        value.fonts.body = theme.fonts.caption
        value.fonts.chat = theme.fonts.caption
        value.fonts.label = theme.fonts.caption
        value.spacing.transcriptMaxWidth = .infinity
        return value
    }
}

private struct CodexSubagentStopwatchV2: View {
    @Environment(\.codexAgentTheme) private var theme
    let status: CodexSubagentLiveStatusV2
    @State private var clientStartedAt = Date()

    var body: some View {
        switch status {
        case .pending: Text("Starting").font(theme.fonts.caption)
        case .working(let since):
            Text(CodexWorkBlockViewV2.workingLabel(at: Date(), since: since, clientStartedAt: clientStartedAt))
                .font(theme.fonts.caption)
        case .completed(let duration): Text(CodexWorkBlockViewV2.completedLabel(duration)).font(theme.fonts.caption)
        case .failed: Text("Failed").font(theme.fonts.caption).foregroundStyle(theme.colors.danger)
        }
    }
}
