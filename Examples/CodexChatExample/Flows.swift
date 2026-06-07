import SwiftUI
import CodexCore
import CodexCoreUI

// MARK: - Welcome

struct WelcomeFlowView: View {
    @Bindable var model: CodexChatModel

    var body: some View {
        CodexGlassPanel {
            VStack(spacing: CodexTheme.Space.xl) {
                CodexBrandMark(size: 60)

                VStack(spacing: 8) {
                    Text("Start a Codex chat")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(CodexTheme.primary)
                    Text("Connect to your local Codex app-server. If your installed Codex is already signed in, you'll go straight to chat.")
                        .font(.system(size: 14))
                        .foregroundStyle(CodexTheme.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }

                VStack(spacing: 10) {
                    CodexLabeledTextField(title: "Workspace", subtitle: "Where Codex reads and writes files", text: $model.workspacePath, systemImage: "folder")
                    CodexLabeledTextField(title: "Codex binary", subtitle: "Leave blank to use PATH", text: $model.codexBinaryPath, systemImage: "terminal")
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
                            ProgressView().controlSize(.small).tint(CodexTheme.onAccent)
                        } else {
                            Image(systemName: "bolt.fill").font(.system(size: 13))
                        }
                        Text(model.isConnecting ? "Connecting…" : "Connect")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(CodexTheme.onAccent)
                    .frame(maxWidth: 460)
                    .frame(height: 44)
                    .background(CodexTheme.accent, in: RoundedRectangle(cornerRadius: CodexTheme.Radius.md, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(model.isConnecting)

                Text("Uses CODEX_HOME=\(defaultCodexHome()) for installed auth.")
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.tertiary)
            }
        }
    }
}

// MARK: - Sign in

struct SignInFlowView: View {
    @Bindable var model: CodexChatModel
    let openURL: OpenURLAction

    var body: some View {
        CodexGlassPanel {
            VStack(spacing: CodexTheme.Space.xl) {
                CodexBrandMark(systemImage: "person.badge.key.fill", size: 60)

                VStack(spacing: 8) {
                    Text("Sign in to continue")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(CodexTheme.primary)
                    Text("Codex didn't find a usable ChatGPT account or API key. Complete one step, then your chat opens automatically.")
                        .font(.system(size: 14))
                        .foregroundStyle(CodexTheme.secondary)
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
                        .foregroundStyle(CodexTheme.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(CodexTheme.accent, in: RoundedRectangle(cornerRadius: CodexTheme.Radius.md, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    if let code = model.deviceCode {
                        CodexDeviceCodeCard(code: code, urlString: model.deviceCodeURL, openURL: openURL)
                    }

                    HStack(spacing: 10) {
                        Rectangle().fill(CodexTheme.stroke).frame(height: 1)
                        Text("or use an API key")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(CodexTheme.tertiary)
                            .fixedSize()
                        Rectangle().fill(CodexTheme.stroke).frame(height: 1)
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
                    .foregroundStyle(CodexTheme.secondary)
            }
        }
    }
}

// MARK: - Preparing

struct PreparingChatView: View {
    let model: CodexChatModel

    var body: some View {
        CodexGlassPanel {
            VStack(spacing: CodexTheme.Space.lg) {
                ProgressView().controlSize(.large).tint(CodexTheme.accent)
                Text("Preparing your chat")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(CodexTheme.primary)
                Text(model.serverName.map { "Connected to \($0). Creating a workspace thread…" } ?? "Creating a workspace thread…")
                    .font(.system(size: 14))
                    .foregroundStyle(CodexTheme.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
