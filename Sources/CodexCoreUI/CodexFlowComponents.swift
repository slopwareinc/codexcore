import SwiftUI

// Generic, theme-driven building blocks for onboarding / auth flows. Host-app
// agnostic (they read only the injected CodexAgentTheme), so they live in
// CodexCoreUI alongside CodexBrandMark for any host to reuse.

public struct CodexGlassPanel<Content: View>: View {
    @Environment(\.codexAgentTheme) private var theme

    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(theme.spacing.xl)
            .frame(maxWidth: 540)
            .codexGlass(RoundedRectangle(cornerRadius: theme.radii.panel, style: .continuous), role: .panel)
            .padding(theme.spacing.xl)
    }
}

public struct CodexErrorBanner: View {
    @Environment(\.codexAgentTheme) private var theme

    private let message: String

    public init(message: String) {
        self.message = message
    }

    public var body: some View {
        Label {
            Text(message)
                .font(theme.fonts.caption)
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

public struct CodexDeviceCodeCard: View {
    @Environment(\.codexAgentTheme) private var theme

    private let code: String
    private let urlString: String?
    private let openURL: OpenURLAction

    public init(code: String, urlString: String?, openURL: OpenURLAction) {
        self.code = code
        self.urlString = urlString
        self.openURL = openURL
    }

    public var body: some View {
        VStack(spacing: 10) {
            Text("Enter this code in your browser")
                .font(theme.fonts.panelLabel)
                .foregroundStyle(theme.colors.textSecondary)
            Text(code)
                .font(theme.fonts.heroTitle.monospaced())
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
                    .font(theme.fonts.chipLabel)
                    .foregroundStyle(theme.colors.accent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(theme.colors.accentSoft, in: RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous))
    }
}
