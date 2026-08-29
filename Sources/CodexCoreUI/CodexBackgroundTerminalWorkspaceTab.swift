import CodexCore
import Foundation
import SwiftUI

/// Metadata-only workspace tab for a server-owned background process.
///
/// The current app-server protocol exposes thread-owned background terminal
/// facts and terminate/clean mutations, but no stream-attachment endpoint.
/// This adapter therefore never fabricates a Ghostty PTY: it presents the
/// canonical command, working directory, process identifiers, and the one
/// supported destructive action.
@MainActor
package struct CodexBackgroundTerminalWorkspaceTabAdapter: CodexWorkspaceTabAdapter {
    private let threadID: ThreadID
    private let terminal: CanonicalBackgroundTerminal
    private let onTerminate: @MainActor () -> Void

    package init(
        threadID: ThreadID,
        terminal: CanonicalBackgroundTerminal,
        onTerminate: @escaping @MainActor () -> Void
    ) {
        self.threadID = threadID
        self.terminal = terminal
        self.onTerminate = onTerminate
    }

    package var workspaceTabRegistration: CodexWorkspaceTabRegistration {
        let route = CodexWorkspaceTabRoute(
            adapterID: "codex.background-terminal",
            version: 1,
            resourceID: resourceID,
            payload: (try? JSONEncoder().encode(RoutePayload(
                threadID: threadID,
                processID: terminal.processID,
                command: terminal.command,
                cwd: terminal.cwd,
                itemID: terminal.itemID
            ))) ?? Data()
        )
        return CodexWorkspaceTabRegistration(
            resourceKey: resourceKey,
            title: CodexTerminalTitleFormatter.title(for: terminal.command),
            systemImage: "terminal",
            lifetime: .preview,
            durableRoute: route,
            routeReplacementKey: resourceKey
        ) { _ in
            AnyView(CodexBackgroundTerminalDetailView(
                terminal: terminal,
                onTerminate: onTerminate
            ))
        }
    }

    private struct RoutePayload: Codable {
        let threadID: ThreadID
        let processID: String
        let command: String
        let cwd: CodexJSONValue
        let itemID: String
    }

    private var resourceID: String {
        "\(threadID.rawValue):\(terminal.processID)"
    }

    private var resourceKey: String {
        "codex.background-terminal:\(resourceID)"
    }
}

private struct CodexBackgroundTerminalDetailView: View {
    @Environment(\.codexAgentTheme) private var theme

    let terminal: CanonicalBackgroundTerminal
    let onTerminate: () -> Void

    private var cwd: String {
        if case .string(let value) = terminal.cwd { return value }
        return String(describing: terminal.cwd)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Background process", systemImage: "terminal")
                        .font(theme.fonts.panelTitle)
                        .foregroundStyle(theme.colors.textPrimary)
                    Text("Server-owned process details")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                }

                detailRow("Command", terminal.command)
                detailRow("Working directory", cwd)
                detailRow("Process", terminal.processID)
                detailRow("Item", terminal.itemID)
                if let osPID = terminal.osPID {
                    detailRow("OS process", String(osPID))
                }
                if let cpuPercent = terminal.cpuPercent {
                    detailRow("CPU", String(format: "%.1f%%", cpuPercent))
                }
                if let rssKB = terminal.rssKB {
                    detailRow("Memory", "\(rssKB) KB")
                }

                Button("Terminate process", role: .destructive, action: onTerminate)
                    .buttonStyle(.borderedProminent)
                    .help("Terminate this server-owned process")
                    .accessibilityLabel("Terminate background process")
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(theme.colors.surfaceSunken.opacity(0.8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Background process details")
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(theme.fonts.micro.weight(.semibold))
                .foregroundStyle(theme.colors.textTertiary)
            Text(value)
                .font(theme.fonts.body)
                .foregroundStyle(theme.colors.textPrimary)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        }
    }
}
