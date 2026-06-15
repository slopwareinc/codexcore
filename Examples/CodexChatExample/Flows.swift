import SwiftUI
import CodexCore
import CodexCoreUI

// MARK: - Welcome

struct WelcomeFlowView: View {
    @Environment(\.codexAgentTheme) private var theme

    @Bindable var model: CodexChatModel

    var body: some View {
        CodexGlassPanel {
            VStack(spacing: 24) {
                CodexBrandMark(size: 60)

                VStack(spacing: 8) {
                    Text("Start a Codex chat")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(theme.colors.textPrimary)
                    Text("Connect to your local Codex app-server. If your installed Codex is already signed in, you'll go straight to chat.")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }

                VStack(spacing: 10) {
                    CodexLabeledTextField(title: "Workspace", subtitle: "Where Codex reads and writes files", text: $model.workspacePath, systemImage: "folder")
                }
                .frame(maxWidth: 460)

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
                            Image(systemName: "bolt.fill").font(.system(size: 13))
                        }
                        Text(model.isConnecting ? "Connecting…" : "Connect")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(theme.colors.onAccent)
                    .frame(maxWidth: 460)
                    .frame(height: 44)
                    .background(theme.colors.accent, in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(model.isConnecting)

                Text("Uses CODEX_HOME=\(defaultCodexHome()) for installed auth.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.colors.textTertiary)
            }
        }
    }
}

// MARK: - Sign in

struct SignInFlowView: View {
    @Environment(\.codexAgentTheme) private var theme

    @Bindable var model: CodexChatModel
    let openURL: OpenURLAction

    var body: some View {
        CodexGlassPanel {
            VStack(spacing: 24) {
                CodexBrandMark(systemImage: "person.badge.key.fill", size: 60)

                VStack(spacing: 8) {
                    Text("Sign in to continue")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(theme.colors.textPrimary)
                    Text("Codex didn't find a usable ChatGPT account or API key. Complete one step, then your chat opens automatically.")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }

                VStack(spacing: 12) {
                    Button {
                        Task { await model.startDeviceCodeLogin() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles").font(.system(size: 13))
                            Text(model.deviceCode == nil ? "Continue with ChatGPT" : "Device login in progress")
                                .font(.system(size: 14, weight: .semibold))
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
                            .font(.system(size: 11, weight: .medium))
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
                    .font(.system(size: 12))
                    .foregroundStyle(theme.colors.textSecondary)
            }
        }
    }
}

// MARK: - Preparing

struct PreparingChatView: View {
    @Environment(\.codexAgentTheme) private var theme

    let model: CodexChatModel

    var body: some View {
        CodexGlassPanel {
            VStack(spacing: 16) {
                ProgressView().controlSize(.large).tint(theme.colors.accent)
                Text("Preparing your chat")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Text(model.serverName.map { "Connected to \($0). Loading chat…" } ?? "Loading chat…")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
