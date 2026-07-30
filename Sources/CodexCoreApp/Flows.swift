import SwiftUI
import CodexCore
import CodexCoreUI

// MARK: - Welcome

struct WelcomeFlowView: View {
    @Environment(\.codexAgentTheme) private var theme

    @Bindable var model: CodexCoreAppModel

    var body: some View {
        CodexGlassPanel {
            VStack(spacing: theme.spacing.xl) {
                CodexBrandMark(size: theme.spacing.iconLarge + 12)

                VStack(spacing: 8) {
                    Text(model.isConnecting ? "Starting Codex" : "Codex is ready to start")
                        .font(theme.fonts.heroTitle)
                        .foregroundStyle(theme.colors.textPrimary)
                    Text("Codex opens with your default workspace and keeps recent projects available in the sidebar.")
                        .font(theme.fonts.body)
                        .foregroundStyle(theme.colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }

                if let message = model.connectionErrorMessage {
                    CodexErrorBanner(message: message).frame(maxWidth: 460)
                }

                Button {
                    Task { await model.connect() }
                } label: {
                    HStack(spacing: 8) {
                        if model.isConnecting {
                            ProgressView().controlSize(.small).tint(theme.colors.onAccent)
                        } else {
                            Image(systemName: "bolt.fill").font(theme.fonts.caption)
                        }
                        Text(model.isConnecting ? "Connecting…" : "Retry")
                            .font(theme.fonts.label)
                    }
                    .foregroundStyle(theme.colors.onAccent)
                    .frame(maxWidth: 460)
                    .frame(height: 44)
                    .background(theme.colors.accent, in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(model.isConnecting)

                Text("Uses CODEX_HOME=\(model.codexHome.path) for isolated auth and state.")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
            }
        }
    }
}

// MARK: - Sign in

struct SignInFlowView: View {
    @Environment(\.codexAgentTheme) private var theme

    @Bindable var model: CodexCoreAppModel
    let openURL: OpenURLAction

    var body: some View {
        CodexGlassPanel {
            VStack(spacing: theme.spacing.xl) {
                CodexBrandMark(systemImage: "person.badge.key.fill", size: theme.spacing.iconLarge + 12)

                VStack(spacing: 8) {
                    Text("Sign in to continue")
                        .font(theme.fonts.heroTitle)
                        .foregroundStyle(theme.colors.textPrimary)
                    Text("Codex didn't find a usable ChatGPT account or API key. Complete one step, then your chat opens automatically.")
                        .font(theme.fonts.body)
                        .foregroundStyle(theme.colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }

                VStack(spacing: 12) {
                    Button {
                        Task { await model.startDeviceCodeLogin() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles").font(theme.fonts.caption)
                            Text(model.deviceCode == nil ? "Continue with ChatGPT" : "Device login in progress")
                                .font(theme.fonts.label)
                        }
                        .foregroundStyle(theme.colors.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(theme.colors.accent, in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    if let code = model.deviceCode {
                        CodexDeviceCodeCard(code: code, urlString: model.deviceCodeURL, openURL: openURL)
                    }

                    HStack(spacing: 10) {
                        Rectangle().fill(theme.colors.border).frame(height: 1)
                        Text("or use an API key")
                            .font(theme.fonts.chipLabel)
                            .foregroundStyle(theme.colors.textTertiary)
                            .fixedSize()
                        Rectangle().fill(theme.colors.border).frame(height: 1)
                    }

                    HStack(spacing: 8) {
                        SecureField("OpenAI API key", text: $model.apiKey)
                            .textFieldStyle(.roundedBorder)
                        Button("Use key") { Task { await model.loginWithAPIKey() } }
                            .disabled(model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .frame(maxWidth: 440)

                Button("Disconnect") { Task { await model.disconnect() } }
                    .buttonStyle(.plain)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
        }
    }
}
