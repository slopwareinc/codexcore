import SwiftUI
import CodexCore

public struct CodexRateLimitBanner: View {
    @Environment(\.codexAgentTheme) private var theme

    private let message: String

    public init(message: String) {
        self.message = message
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.colors.warning)

            Text(message)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(theme.colors.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.warning.opacity(0.35), lineWidth: 1)
        )
    }
}
