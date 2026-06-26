import SwiftUI

struct CodexSubagentRunInlineView: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var showsDetails = false

    let events: [CodexAgentLifecycleEvent]
    private let summary: CodexSubagentRunSummary

    init(events: [CodexAgentLifecycleEvent]) {
        self.events = events
        self.summary = CodexSubagentRunSummary(events: events)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: theme.animations.snappyDuration)) {
                    showsDetails.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    aggregateIcon
                        .frame(width: theme.spacing.iconMedium, height: theme.spacing.iconMedium)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(summary.title)
                                .font(theme.fonts.label)
                                .foregroundStyle(theme.colors.textPrimary)
                                .lineLimit(1)
                            Text(summary.agentCountLabel)
                                .font(theme.fonts.micro)
                                .foregroundStyle(theme.colors.textTertiary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(theme.colors.surfaceElevated.opacity(0.28), in: Capsule())
                        }

                        Text(summary.detail)
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.textTertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    if let date = summary.date {
                        Text(date, format: .dateTime.hour().minute())
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.textTertiary)
                    }

                    Image(systemName: "chevron.right")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .rotationEffect(.degrees(showsDetails ? 90 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(theme.colors.surfaceElevated.opacity(0.18))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsDetails {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(summary.milestones) { milestone in
                        HStack(spacing: 8) {
                            miniIcon(for: milestone.status)
                                .frame(width: theme.spacing.iconSmall, height: theme.spacing.iconSmall)
                            Text(milestone.title)
                                .font(theme.fonts.caption)
                                .foregroundStyle(theme.colors.textTertiary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(theme.colors.surface.opacity(0.32))
            }
        }
        .background(theme.colors.surface.opacity(theme.effects.glassOpacity * 0.86))
        .clipShape(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.border.opacity(0.72), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var aggregateIcon: some View {
        switch summary.status {
        case .spawning, .running:
            ProgressView()
                .controlSize(.mini)
                .tint(theme.colors.running)
        case .completed, .closed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(theme.colors.success)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.colors.danger)
        }
    }

    @ViewBuilder
    private func miniIcon(for status: CodexAgentLifecycleEvent.Status) -> some View {
        switch status {
        case .spawning:
            Image(systemName: "sparkles")
                .foregroundStyle(theme.colors.accent)
        case .running:
            ProgressView()
                .controlSize(.mini)
                .tint(theme.colors.running)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(theme.colors.success)
        case .closed:
            Image(systemName: "archivebox.fill")
                .foregroundStyle(theme.colors.textTertiary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.colors.danger)
        }
    }
}

struct CodexSubagentRunSummary: Equatable {
    struct Milestone: Identifiable, Equatable {
        var id: String
        var status: CodexAgentLifecycleEvent.Status
        var title: String
    }

    var status: CodexAgentLifecycleEvent.Status
    var title: String
    var detail: String
    var agentCountLabel: String
    var milestones: [Milestone]
    var date: Date?

    init(events: [CodexAgentLifecycleEvent]) {
        let sortedEvents = events.sorted { $0.createdAt < $1.createdAt }
        let names = Self.uniqueAgentNames(in: sortedEvents)
        let count = max(names.count, Self.inferredAgentCount(in: sortedEvents))
        let status = Self.aggregateStatus(from: sortedEvents)

        self.status = status
        self.title = Self.title(for: status)
        self.detail = Self.detail(for: status, names: names)
        self.agentCountLabel = count == 1 ? "1 agent" : "\(count) agents"
        self.milestones = Self.milestones(from: sortedEvents, names: names, count: count)
        self.date = sortedEvents.last?.createdAt
    }

    private static func aggregateStatus(from events: [CodexAgentLifecycleEvent]) -> CodexAgentLifecycleEvent.Status {
        guard let latest = events.last else { return .running }
        if let terminal = events.last(where: { $0.status == .failed || $0.status == .completed || $0.status == .closed }) {
            return terminal.status == .failed ? .failed : .completed
        }
        return latest.status
    }

    private static func title(for status: CodexAgentLifecycleEvent.Status) -> String {
        switch status {
        case .failed:
            return "Subagent run failed"
        case .running, .spawning:
            return "Subagents running"
        case .completed, .closed:
            return "Subagent run complete"
        }
    }

    private static func detail(for status: CodexAgentLifecycleEvent.Status, names: [String]) -> String {
        if !names.isEmpty {
            let listed = names.prefix(3).joined(separator: ", ")
            let suffix = names.count > 3 ? " +\(names.count - 3)" : ""
            switch status {
            case .failed:
                return "\(listed)\(suffix) hit an error."
            case .running, .spawning:
                return "\(listed)\(suffix) active. Open side chat for transcripts."
            case .completed, .closed:
                return "\(listed)\(suffix) finished. Full transcripts are in side chat."
            }
        }

        switch status {
        case .failed:
            return "A delegated agent hit an error."
        case .running, .spawning:
            return "Delegated agents are active."
        case .completed, .closed:
            return "Delegated agents finished."
        }
    }

    private static func milestones(
        from events: [CodexAgentLifecycleEvent],
        names: [String],
        count: Int
    ) -> [Milestone] {
        var rows: [Milestone] = []

        let spawnEvents = events.filter { isSpawnEvent($0) }
        if !spawnEvents.isEmpty {
            let isStarted = spawnEvents.contains { $0.status != .spawning || $0.title.hasPrefix("Spawned ") }
            rows.append(Milestone(
                id: "spawn",
                status: isStarted ? .completed : .spawning,
                title: isStarted ? "Spawned \(agentLabel(names: names, count: count))" : "Starting \(agentLabel(names: names, count: count))"
            ))
        }

        if events.contains(where: isWaitCompleteEvent) {
            rows.append(Milestone(id: "wait-complete", status: .completed, title: "Received agent output"))
        } else if let waiting = events.last(where: isWaitEvent) {
            rows.append(Milestone(id: "wait", status: .running, title: normalizedDetailTitle(waiting.title)))
        }

        if let failed = events.last(where: { $0.status == .failed }) {
            rows.append(Milestone(id: "failed", status: .failed, title: normalizedDetailTitle(failed.title)))
        }

        if rows.isEmpty, let latest = events.last {
            rows.append(Milestone(id: "latest", status: latest.status, title: normalizedDetailTitle(latest.title)))
        }

        return rows
    }

    private static func uniqueAgentNames(in events: [CodexAgentLifecycleEvent]) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for name in events.flatMap(\.agentNames) where !seen.contains(name) {
            seen.insert(name)
            names.append(name)
        }
        return names
    }

    private static func inferredAgentCount(in events: [CodexAgentLifecycleEvent]) -> Int {
        var count = events.isEmpty ? 0 : 1
        for event in events {
            let parts = event.title.split(separator: " ")
            for part in parts {
                if let value = Int(part), event.title.contains("agent") {
                    count = max(count, value)
                }
            }
            count = max(count, event.agentNames.count)
        }
        return count
    }

    private static func agentLabel(names: [String], count: Int) -> String {
        if names.count == 1 { return names[0] }
        if names.count > 1 { return "\(names.count) agents" }
        return count == 1 ? "1 agent" : "\(count) agents"
    }

    private static func isSpawnEvent(_ event: CodexAgentLifecycleEvent) -> Bool {
        event.title.hasPrefix("Spawning ") || event.title.hasPrefix("Spawned ")
    }

    private static func isWaitEvent(_ event: CodexAgentLifecycleEvent) -> Bool {
        event.title.hasPrefix("Waiting ") || event.title == "Finished waiting"
    }

    private static func isWaitCompleteEvent(_ event: CodexAgentLifecycleEvent) -> Bool {
        event.title == "Finished waiting" || event.title == "Received agent output"
    }

    private static func isCloseEvent(_ event: CodexAgentLifecycleEvent) -> Bool {
        event.title.hasPrefix("Closing ") || event.title.hasPrefix("Closed ")
    }

    private static func normalizedDetailTitle(_ title: String) -> String {
        if title == "Finished waiting" { return "Received agent output" }
        if title.hasPrefix("Completed 1 agent") { return "Received agent output" }
        if title.hasPrefix("Closed ") { return "Subagent session closed" }
        return title
    }
}
