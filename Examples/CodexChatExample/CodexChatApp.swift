import SwiftUI
import AppKit
import CodexCore
import CodexCoreUI

@main
struct CodexChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            CodexChatView()
                .frame(minWidth: 940, minHeight: 660)
        }
        .windowResizability(.contentMinSize)
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
    @State private var model = CodexChatModel()
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
        .tint(CodexTheme.accent)
    }

    private var flowKey: String {
        if model.showsChatWorkspace { return "chat" }
        if !model.isConnected { return "connect" }
        if !model.isAuthenticated { return "sign-in" }
        return "prepare"
    }
}

// MARK: - Workspace

struct ChatWorkspaceView: View {
    @Bindable var model: CodexChatModel

    var body: some View {
        CodexChatWorkspaceView(
            messages: model.messages,
            activities: model.activities,
            connectionState: model.connectionState,
            workspacePath: model.workspacePath,
            serverName: model.serverName,
            authLabel: model.authLabel,
            isAuthenticated: model.isAuthenticated,
            isThreadReady: model.isThreadReady,
            draft: $model.draft,
            isSending: model.isSending,
            canSend: model.canSend,
            onSend: { Task { await model.sendDraft() } },
            onInterrupt: { Task { await model.interrupt() } },
            onDisconnect: { Task { await model.disconnect() } }
        )
    }
}
