import SwiftUI

@available(macOS 14.0, iOS 17.0, *)
struct CodexStatusChip: View {
    @Environment(\.codexAgentTheme) private var theme

    let color: Color
    let label: String
    let isStreaming: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: isStreaming ? 7 : 6, height: isStreaming ? 7 : 6)
            Text(label)
                .font(theme.fonts.micro)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.16), in: Capsule())
    }
}
