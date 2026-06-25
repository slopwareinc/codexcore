import SwiftUI

/// Minimal in-transcript working indicator matching the official Codex app live-turn state.
struct CodexTurnWorkingBlock: View {
    @Environment(\.codexAgentTheme) private var theme

    let state: CodexActiveTurnState

    var body: some View {
        let phase = CodexLiveTurnModel.phaseState(for: state)

        HStack(spacing: 8) {
            Circle()
                .fill(theme.colors.running)
                .frame(width: 7, height: 7)
                .frame(width: 14, height: 14)

            Text(phase.statusTitle)
                .font(theme.fonts.label)
                .foregroundStyle(theme.colors.textSecondary)
                .lineLimit(1)

            Text(phase.thinkingTitle)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textTertiary)
                .lineLimit(1)

            Text(phase.elapsedLabel)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textTertiary)
                .lineLimit(1)

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

    private func accessibilityLabel(for phase: CodexLiveTurnPhaseState) -> String {
        var parts = [phase.statusTitle, phase.thinkingTitle, phase.elapsedLabel]
        if let stopTitle = phase.stopTitle {
            parts.append([stopTitle, phase.stopShortcut].compactMap(\.self).joined(separator: " "))
        }
        return parts.joined(separator: ", ")
    }
}
