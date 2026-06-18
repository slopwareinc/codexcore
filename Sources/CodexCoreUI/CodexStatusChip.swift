import SwiftUI

@available(macOS 14.0, iOS 17.0, *)
struct CodexStatusChip: View {
    @Environment(\.codexAgentTheme) private var theme

    let color: Color
    let label: String
    let isStreaming: Bool

    var body: some View {
        HStack(spacing: 5) {
            if isStreaming {
                ProgressView()
                    .controlSize(.mini)
                    .tint(color)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
            Text(label)
                .font(theme.fonts.micro)
                .foregroundStyle(color)
        }
        .padding(theme.spacing.chipPadding)
        .background(color.opacity(0.16), in: Capsule())
    }
}
