import SwiftUI

/// Minimal in-transcript working indicator matching the official Codex app live-turn state.
struct CodexTurnWorkingBlock: View {
    @Environment(\.codexAgentTheme) private var theme

    let state: CodexActiveTurnState

    var body: some View {
        TimelineView(.periodic(from: state.startedAt, by: 1)) { timeline in
            let phase = CodexLiveTurnModel.phaseState(for: state, now: timeline.date)

            HStack(spacing: 8) {
                Circle()
                    .fill(theme.colors.running)
                    .frame(width: 7, height: 7)
                    .frame(width: 14, height: 14)

                Text(phase.title)
                    .font(theme.fonts.label)
                    .foregroundStyle(theme.colors.textSecondary)
                    .lineLimit(1)

                if let detail = phase.detail {
                    Text(detail)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Text(phase.elapsedLabel)
                    .font(theme.fonts.caption.monospacedDigit())
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(1)
                    .accessibilityLabel("Elapsed \(phase.elapsedLabel)")

                if let stopTitle = phase.stopTitle {
                    HStack(spacing: 5) {
                        Text(stopTitle)
                        if let shortcut = phase.stopShortcut {
                            Text(shortcut)
                                .foregroundStyle(theme.colors.textTertiary)
                        }
                    }
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(theme.colors.surfaceElevated.opacity(theme.effects.textFaintOpacity), in: Capsule())
                }

                Image(systemName: "chevron.right")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary.opacity(0.72))
            }
            .padding(.leading, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(accessibilityLabel(for: phase))
        }
    }

    private func accessibilityLabel(for phase: CodexLiveTurnPhaseState) -> String {
        var parts = [phase.title]
        if let detail = phase.detail {
            parts.append(detail)
        }
        parts.append("elapsed \(phase.elapsedLabel)")
        if let stopTitle = phase.stopTitle {
            parts.append([stopTitle, phase.stopShortcut].compactMap(\.self).joined(separator: " "))
        }
        return parts.joined(separator: ", ")
    }
}
