import SwiftUI
import CodexCoreUI

struct CodexGlassPanel<Content: View>: View {
    @Environment(\.codexAgentTheme) private var theme

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(34)
            .frame(maxWidth: 540)
            .codexGlass(RoundedRectangle(cornerRadius: theme.radii.panel, style: .continuous))
            .padding(28)
    }
}

struct CodexErrorBanner: View {
    @Environment(\.codexAgentTheme) private var theme

    private let message: String

    init(message: String) {
        self.message = message
    }

    var body: some View {
        Label {
            Text(message)
                .font(.system(size: 12))
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(theme.colors.danger)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.colors.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
    }
}

struct CodexDeviceCodeCard: View {
    @Environment(\.codexAgentTheme) private var theme

    private let code: String
    private let urlString: String?
    private let openURL: OpenURLAction

    init(code: String, urlString: String?, openURL: OpenURLAction) {
        self.code = code
        self.urlString = urlString
        self.openURL = openURL
    }

    var body: some View {
        VStack(spacing: 10) {
            Text("Enter this code in your browser")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(theme.colors.textSecondary)
            Text(code)
                .font(.system(size: 26, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.colors.textPrimary)
                .tracking(3)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(theme.colors.surface, in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                        .stroke(theme.colors.border, lineWidth: 1)
                )
            if let urlString, let url = URL(string: urlString) {
                Button("Open sign-in page") { openURL(url) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.colors.accent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(theme.colors.accentSoft, in: RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous))
    }
}
