import SwiftUI

/// Minimal in-transcript working indicator matching the official Codex app ("Worked for 28s >").
struct CodexTurnWorkingBlock: View {
    @Environment(\.codexAgentTheme) private var theme

    let state: CodexActiveTurnState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                Text(label(at: context.date))
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary.opacity(0.72))
            }
            .padding(.leading, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(label(at: context.date))
        }
    }

    private func label(at date: Date) -> String {
        let elapsed = max(0, Int(date.timeIntervalSince(state.startedAt)))
        if elapsed >= 1 {
            return "Worked for \(elapsed)s"
        }
        let title = state.activity?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Working" : title
    }
}
