import AppKit
import GhosttyTerminal
import SwiftUI

@MainActor
public final class CodexTerminalSession: Identifiable {
    public let id: String
    public let title: String
    public let initialWorkingDirectory: String
    public let state: TerminalViewState

    /// The ghostty AppKit view (and therefore the live surface/PTY) is owned by
    /// the session, not by the SwiftUI representable that shows it. Ghostty frees
    /// the surface only when this view deallocates, so keeping the same view
    /// instance across panel-hide and chat-switch keeps the shell alive; only the
    /// view's window attachment recycles.
    let terminalView: TerminalView

    public init(
        id: String = "terminal:\(UUID().uuidString)",
        title: String = "Terminal",
        workingDirectory: String,
        fontSize: Float = 13
    ) {
        self.id = id
        self.title = title
        self.initialWorkingDirectory = workingDirectory
        self.state = TerminalViewState(
            terminalConfiguration: TerminalConfiguration { builder in
                builder.withBackgroundOpacity(0)
                builder.withWindowPaddingX(8)
                builder.withWindowPaddingY(8)
                builder.withCursorStyle(.block)
                builder.withCursorStyleBlink(true)
            }
        )
        self.state.configuration = TerminalSurfaceOptions(
            backend: .exec,
            fontSize: fontSize,
            workingDirectory: workingDirectory,
            context: .window
        )

        let view = TerminalView(frame: .zero)
        view.delegate = state
        view.controller = state.controller
        view.configuration = state.configuration
        self.terminalView = view
    }
}

public struct CodexTerminalToolView: View {
    @Environment(\.codexAgentTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var terminalState: TerminalViewState
    private let session: CodexTerminalSession

    public init(session: CodexTerminalSession) {
        self.session = session
        self.terminalState = session.state
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.colors.border)
            CodexTerminalHostView(session: session)
                .background(theme.colors.surfaceSunken.opacity(0.8))
                .accessibilityLabel("Terminal")
                .onAppear { terminalState.adopt(colorScheme: colorScheme) }
                .onChange(of: colorScheme) { _, newValue in
                    terminalState.adopt(colorScheme: newValue)
                }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textTertiary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(theme.fonts.label)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)

                Text(displayWorkingDirectory)
                    .font(theme.fonts.micro)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            if let size = terminalState.surfaceSize {
                Text("\(size.columns)x\(size.rows)")
                    .font(theme.fonts.micro.weight(.semibold))
                    .foregroundStyle(theme.colors.textTertiary)
            }

            if let exitCode = terminalState.lastCommandExitCode {
                Text(exitCode == 0 ? "OK" : "Exit \(exitCode)")
                    .font(theme.fonts.micro.weight(.semibold))
                    .foregroundStyle(exitCode == 0 ? theme.colors.success : theme.colors.warning)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    private var displayTitle: String {
        terminalState.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? session.title
            : terminalState.title
    }

    private var displayWorkingDirectory: String {
        CodexTerminalPathFormatter.display(terminalState.workingDirectory ?? session.initialWorkingDirectory)
    }
}

/// Hosts the session-owned ghostty view. It never creates or tears down the
/// view, so the surface survives the representable being dismantled (panel
/// hidden, chat switched). Lifetime is owned by CodexTerminalSession.
private struct CodexTerminalHostView: NSViewRepresentable {
    let session: CodexTerminalSession

    func makeNSView(context: Context) -> TerminalView {
        let view = session.terminalView
        // Focus the terminal once it lands in a window, matching the previous
        // focus-on-appear behavior without relying on the library's internal
        // focus callback.
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window, window.firstResponder !== view else { return }
            window.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}
}

public enum CodexTerminalPathFormatter {
    public static func display(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

