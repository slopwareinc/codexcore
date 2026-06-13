import SwiftUI
import AppKit
import CodexCore
import CodexCoreUI

@main
struct CodexChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = CodexChatModel()

    var body: some Scene {
        WindowGroup {
            CodexChatView(model: model)
                .frame(minWidth: 940, minHeight: 660)
        }
        .windowResizability(.contentMinSize)

        Settings {
            CodexSettingsView(model: model)
                .codexAgentTheme(model.themePreset.theme)
                .tint(model.themePreset.theme.colors.accent)
        }
    }
}

/// Promotes the CLI-launched binary to a regular foreground app so it gets a
/// Dock icon, a menu bar, and — crucially — keyboard focus for text fields.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct CodexChatView: View {
    @Bindable var model: CodexChatModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            CodexBackdrop()

            Group {
                if model.showsChatWorkspace {
                    ChatWorkspaceView(model: model)
                        .transition(.opacity)
                } else if !model.isConnected {
                    WelcomeFlowView(model: model)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else if !model.isAuthenticated {
                    SignInFlowView(model: model, openURL: openURL)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    PreparingChatView(model: model)
                        .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.9), value: flowKey)
        }
        .codexAgentTheme(model.themePreset.theme)
        .tint(model.themePreset.theme.colors.accent)
    }

    private var flowKey: String {
        if model.showsChatWorkspace { return "chat" }
        if !model.isConnected { return "connect" }
        if !model.isAuthenticated { return "sign-in" }
        return "prepare"
    }
}

private struct CodexSettingsView: View {
    @Environment(\.codexAgentTheme) private var theme
    @Bindable var model: CodexChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Settings")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Text("Customize the Codex chat example.")
                    .font(theme.fonts.chat)
                    .foregroundStyle(theme.colors.textSecondary)
            }

            Divider().overlay(theme.colors.border)

            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Theme")
                        .font(theme.fonts.label)
                        .foregroundStyle(theme.colors.textPrimary)
                    Text("Applies to the whole workspace, including side chats and subagents.")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                }

                Spacer(minLength: 24)

                ThemePresetPicker(model: model)
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 420, height: 220, alignment: .topLeading)
        .background(theme.colors.canvas)
    }
}

private struct ThemePresetPicker: View {
    @Bindable var model: CodexChatModel

    var body: some View {
        Picker("Theme", selection: $model.themePreset) {
            ForEach(CodexAgentThemePreset.allCases) { preset in
                Text(preset.displayName).tag(preset)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 156)
        .codexGlass(Capsule(), interactive: true)
    }
}

// MARK: - Workspace

struct ChatWorkspaceView: View {
    @Bindable var model: CodexChatModel

    var body: some View {
        CodexExampleAppShell(model: model)
    }
}
