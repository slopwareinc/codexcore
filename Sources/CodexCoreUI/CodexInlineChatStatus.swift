import SwiftUI

/// Minimal in-transcript working indicator matching the official Codex app live-turn state.
struct CodexTurnWorkingBlock: View {
    @Environment(\.codexAgentTheme) private var theme

    let state: CodexActiveTurnState

    var body: some View {
        TimelineView(.periodic(from: state.startedAt, by: 1)) { timeline in
            let phase = CodexLiveTurnModel.phaseState(for: state, now: timeline.date)

            // Same leading edge as assistant text / Worked-for (no old avatar offset).
            HStack(alignment: .center, spacing: 6) {
                Circle()
                    .fill(theme.colors.running)
                    .frame(width: 6, height: 6)

                // Official app chrome: "Working for 23s" as one muted phrase.
                Text("\(phase.title) for \(phase.elapsedLabel)")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(1)
                    .monospacedDigit()

                if let detail = phase.detail {
                    Text(detail)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let stopTitle = phase.stopTitle {
                    HStack(spacing: 4) {
                        Text(stopTitle)
                        if let shortcut = phase.stopShortcut {
                            Text(shortcut)
                                .foregroundStyle(theme.colors.textTertiary)
                        }
                    }
                    .font(theme.fonts.micro)
                    .foregroundStyle(theme.colors.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.colors.surfaceElevated.opacity(theme.effects.textFaintOpacity), in: Capsule())
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(accessibilityLabel(for: phase))
        }
    }

    private func accessibilityLabel(for phase: CodexLiveTurnPhaseState) -> String {
        var parts = ["\(phase.title) for \(phase.elapsedLabel)"]
        if let detail = phase.detail {
            parts.append(detail)
        }
        if let stopTitle = phase.stopTitle {
            parts.append([stopTitle, phase.stopShortcut].compactMap(\.self).joined(separator: " "))
        }
        return parts.joined(separator: ", ")
    }
}
