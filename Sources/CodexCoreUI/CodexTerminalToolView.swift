import AppKit
import CodexCore
import GhosttyTerminal
import SwiftUI

/// Stable identity for one retained terminal host. The thread and checkout
/// are part of the identity so a terminal from one chat can never be reused by
/// another chat that happens to have the same tab title.
public struct CodexTerminalIdentity: Hashable, Codable, Sendable, Identifiable {
    public let threadID: String?
    public let worktreePath: String
    public let ordinal: Int
    private let explicitRawValue: String?

    public init(
        threadID: String? = nil,
        worktreePath: String,
        ordinal: Int
    ) {
        let trimmedThreadID = threadID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.threadID = trimmedThreadID?.isEmpty == true ? nil : trimmedThreadID
        self.worktreePath = URL(fileURLWithPath: worktreePath).standardizedFileURL.path
        self.ordinal = max(1, ordinal)
        self.explicitRawValue = nil
    }

    private init(rawValue: String, worktreePath: String) {
        self.threadID = nil
        self.worktreePath = worktreePath
        self.ordinal = 1
        self.explicitRawValue = rawValue
    }

    /// A deterministic, human-readable key suitable for workspace routes and
    /// tab resource keys. Paths are intentionally retained instead of hashed so
    /// diagnostics can explain which checkout owns a terminal.
    public var rawValue: String {
        if let explicitRawValue { return explicitRawValue }
        let scope = "terminal:\(threadID ?? "unassigned"):\(worktreePath)"
        return "\(scope):\(ordinal)"
    }

    public var id: String { rawValue }

    static func explicit(rawValue: String, worktreePath: String) -> Self {
        Self(rawValue: rawValue, worktreePath: worktreePath)
    }
}

public enum CodexTerminalTitleFormatter {
    /// Produces a compact title from the command that launched a terminal.
    /// Shell login wrappers and executable path prefixes are removed while the
    /// useful command arguments remain visible in the tab.
    public static func title(for command: String?, fallback: String = "Terminal") -> String {
        guard var value = command?.split(whereSeparator: \.isNewline).first.map(String.init),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return fallback }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let marker = value.range(of: " -lc ") {
            value = String(value[marker.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }

        var tokens = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if tokens.first == "env" {
            tokens.removeFirst()
            while let first = tokens.first, first.contains("=") {
                tokens.removeFirst()
            }
        }
        if let executable = tokens.first, executable.contains("/") {
            tokens[0] = URL(fileURLWithPath: executable).lastPathComponent
        }
        value = tokens.joined(separator: " ")
        guard !value.isEmpty else { return fallback }
        if value.count > 48 {
            return String(value.prefix(45)) + "…"
        }
        return value
    }
}

@MainActor
public final class CodexTerminalSession: Identifiable {
    /// Ghostty's `scrollback-limit` is a byte budget for the native page
    /// buffer. Keeping the limit on the session configuration makes the bound
    /// apply to the actual PTY host rather than to an unconnected Swift-side
    /// transcript copy.
    public static let defaultScrollbackLimitBytes = 256 * 1024

    public let id: String
    public let title: String
    public let initialWorkingDirectory: String
    public let identity: CodexTerminalIdentity
    public let command: String?
    public let isBackground: Bool
    public let state: TerminalViewState
    public private(set) var isSurfaceVisible = true
    public private(set) var surfaceVisibilityChangeCount = 0
    public private(set) var focusRestoreRequestCount = 0

    /// The ghostty AppKit view (and therefore the live surface/PTY) is owned by
    /// the session, not by the SwiftUI representable that shows it. Ghostty frees
    /// the surface only when this view deallocates, so keeping the same view
    /// instance across panel-hide and chat-switch keeps the shell alive; only the
    /// view's window attachment recycles.
    let terminalView: TerminalView
    public let scrollbackLimitBytes: Int

    public init(
        id: String = "terminal:\(UUID().uuidString)",
        title: String? = nil,
        workingDirectory: String,
        fontSize: Float = 13,
        command: String? = nil,
        identity: CodexTerminalIdentity? = nil,
        isBackground: Bool = false,
        scrollbackLimitBytes: Int = CodexTerminalSession.defaultScrollbackLimitBytes
    ) {
        let resolvedIdentity = identity
            ?? .explicit(rawValue: id, worktreePath: workingDirectory)
        self.identity = resolvedIdentity
        self.id = resolvedIdentity.rawValue
        self.command = command
        self.isBackground = isBackground
        self.scrollbackLimitBytes = max(0, scrollbackLimitBytes)
        let fallbackTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = CodexTerminalTitleFormatter.title(
            for: command,
            fallback: fallbackTitle?.isEmpty == false ? fallbackTitle! : "Terminal"
        )
        self.initialWorkingDirectory = workingDirectory
        self.state = TerminalViewState(
            terminalConfiguration: TerminalConfiguration { builder in
                builder.withBackgroundOpacity(0)
                builder.withWindowPaddingX(8)
                builder.withWindowPaddingY(8)
                builder.withCursorStyle(.block)
                builder.withCursorStyleBlink(true)
                builder.withCustom(
                    "scrollback-limit",
                    String(max(0, scrollbackLimitBytes))
                )
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

    public convenience init(
        threadID: String?,
        worktreePath: String,
        ordinal: Int = 1,
        title: String? = nil,
        command: String? = nil,
        fontSize: Float = 13,
        isBackground: Bool = false,
        scrollbackLimitBytes: Int = CodexTerminalSession.defaultScrollbackLimitBytes
    ) {
        self.init(
            title: title,
            workingDirectory: worktreePath,
            fontSize: fontSize,
            command: command,
            identity: CodexTerminalIdentity(
                threadID: threadID,
                worktreePath: worktreePath,
                ordinal: ordinal
            ),
            isBackground: isBackground,
            scrollbackLimitBytes: scrollbackLimitBytes
        )
    }

    /// Stable native-host identity used by mounted-panel tests and diagnostics.
    public var terminalHostIdentity: ObjectIdentifier { ObjectIdentifier(terminalView) }

    /// Updates native display work without touching the retained PTY. Ghostty
    /// stops its display link while hidden; the same session-owned view is
    /// reused when the tab becomes visible again.
    public func setSurfaceVisible(_ visible: Bool) {
        guard visible != isSurfaceVisible else { return }
        isSurfaceVisible = visible
        surfaceVisibilityChangeCount += 1
        terminalView.setSurfaceVisible(visible)
    }

    public func restoreFocus() {
        guard isSurfaceVisible else { return }
        focusRestoreRequestCount += 1
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.terminalView.window,
                  window.firstResponder !== self.terminalView else { return }
            window.makeFirstResponder(self.terminalView)
        }
    }
}

public struct CodexTerminalToolView: View {
    @Environment(\.codexAgentTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var terminalState: TerminalViewState
    private let session: CodexTerminalSession
    /// Whether this terminal is the one currently shown. Sessions belonging to
    /// other retained chats keep their native hosts alive but inactive; Ghostty
    /// occludes them until shown again, and only the active one takes focus.
    private let isActive: Bool

    public init(session: CodexTerminalSession, isActive: Bool = true) {
        self.session = session
        self.terminalState = session.state
        self.isActive = isActive
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.colors.border)
            CodexTerminalHostView(session: session)
                .background(theme.colors.surfaceSunken.opacity(0.8))
                .accessibilityLabel("Terminal")
                .onAppear {
                    terminalState.adopt(colorScheme: colorScheme)
                    applyActiveState(isActive)
                }
                .onChange(of: colorScheme) { _, newValue in
                    terminalState.adopt(colorScheme: newValue)
                }
                .onChange(of: isActive) { _, active in
                    applyActiveState(active)
                }
                .onDisappear {
                    applyActiveState(false)
                }
        }
    }

    private func applyActiveState(_ active: Bool) {
        session.setSurfaceVisible(active)
        guard active else { return }
        // Focus only the active terminal, after it has settled into the window.
        session.restoreFocus()
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
        // Focus is driven by CodexTerminalToolView.applyActiveState so that only
        // the active terminal in the deck grabs first responder, never a hidden one.
        session.terminalView
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}
}

public enum CodexTerminalPathFormatter {
    public static func display(_ path: String) -> String {
        CodexPathFormatter.abbreviatingHome(path)
    }
}

@MainActor
package struct CodexTerminalWorkspaceTabAdapter: CodexWorkspaceTabAdapter {
    package struct RoutePayload: Codable, Sendable {
        package let threadID: String?
        package let worktreePath: String
        package let ordinal: Int
        package let command: String?
        package let isBackground: Bool
    }

    package let session: CodexTerminalSession
    package let placement: CodexWorkspaceTabPlacement
    private let onClose: @MainActor () -> Void
    private let onReopen: @MainActor (CodexWorkspaceTabID) -> Void

    package init(
        session: CodexTerminalSession,
        placement: CodexWorkspaceTabPlacement = .bottom,
        onClose: @escaping @MainActor () -> Void = {},
        onReopen: @escaping @MainActor (CodexWorkspaceTabID) -> Void = { _ in }
    ) {
        self.session = session
        self.placement = placement
        self.onClose = onClose
        self.onReopen = onReopen
    }

    package var workspaceTabRegistration: CodexWorkspaceTabRegistration {
        CodexWorkspaceTabRegistration(
            resourceKey: "codex.terminal:\(session.identity.rawValue)",
            title: session.title,
            systemImage: "terminal",
            lifetime: .pinned,
            durableRoute: .init(
                adapterID: "codex.terminal",
                version: 1,
                resourceID: session.identity.rawValue,
                payload: Self.routePayload(for: session)
            ),
            routeReplacementKey: "codex.terminal:\(session.identity.rawValue)",
            preferredPlacement: placement,
            onClose: onClose,
            onReopen: onReopen,
            onVisibilityChanged: { visible in
                session.setSurfaceVisible(visible)
                if visible { session.restoreFocus() }
            }
        ) { _ in
            AnyView(CodexTerminalToolView(session: session, isActive: false))
        }
    }

    /// Reconstructs a local PTY host from a durable route when the tab is
    /// activated. The panel state keeps this factory lazy so hidden restored
    /// tabs do not launch shells during initialization.
    package static func restoredLocalSession(
        from route: CodexWorkspaceTabRoute
    ) -> CodexTerminalSession? {
        guard let payload = routePayload(from: route) else { return nil }
        return CodexTerminalSession(
            workingDirectory: payload.worktreePath,
            command: payload.command,
            identity: CodexTerminalIdentity(
                threadID: payload.threadID,
                worktreePath: payload.worktreePath,
                ordinal: payload.ordinal
            ),
            isBackground: payload.isBackground
        )
    }

    package static func routePayload(
        from route: CodexWorkspaceTabRoute
    ) -> RoutePayload? {
        guard route.adapterID == "codex.terminal" else { return nil }
        return try? JSONDecoder().decode(RoutePayload.self, from: route.payload)
    }

    private static func routePayload(for session: CodexTerminalSession) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(RoutePayload(
            threadID: session.identity.threadID,
            worktreePath: session.identity.worktreePath,
            ordinal: session.identity.ordinal,
            command: session.command,
            isBackground: session.isBackground
        ))) ?? Data()
    }
}

/// Registration-only adapter for a restored terminal route. Its content
/// factory creates the native session only after the workspace activates the
/// tab, keeping hidden routes cheap and preventing surprise shell launches.
@MainActor
package struct CodexLazyTerminalWorkspaceTabAdapter: CodexWorkspaceTabAdapter {
    private let payload: CodexTerminalWorkspaceTabAdapter.RoutePayload
    private let placement: CodexWorkspaceTabPlacement
    private let materialize: @MainActor () -> CodexTerminalSession?
    private let onClose: @MainActor () -> Void
    private let onReopen: @MainActor () -> Void

    package init(
        payload: CodexTerminalWorkspaceTabAdapter.RoutePayload,
        placement: CodexWorkspaceTabPlacement,
        materialize: @escaping @MainActor () -> CodexTerminalSession?,
        onClose: @escaping @MainActor () -> Void,
        onReopen: @escaping @MainActor () -> Void
    ) {
        self.payload = payload
        self.placement = placement
        self.materialize = materialize
        self.onClose = onClose
        self.onReopen = onReopen
    }

    package var workspaceTabRegistration: CodexWorkspaceTabRegistration {
        let identity = CodexTerminalIdentity(
            threadID: payload.threadID,
            worktreePath: payload.worktreePath,
            ordinal: payload.ordinal
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let route = CodexWorkspaceTabRoute(
            adapterID: "codex.terminal",
            version: 1,
            resourceID: identity.rawValue,
            payload: (try? encoder.encode(payload)) ?? Data()
        )
        return CodexWorkspaceTabRegistration(
            resourceKey: "codex.terminal:\(identity.rawValue)",
            title: CodexTerminalTitleFormatter.title(for: payload.command),
            systemImage: "terminal",
            lifetime: .pinned,
            durableRoute: route,
            routeReplacementKey: "codex.terminal:\(identity.rawValue)",
            preferredPlacement: placement,
            onClose: onClose,
            onReopen: { _ in onReopen() },
            onVisibilityChanged: { visible in
                guard let session = materialize() else { return }
                session.setSurfaceVisible(visible)
                if visible { session.restoreFocus() }
            }
        ) { _ in
            guard let session = materialize() else {
                return AnyView(Text("This terminal is unavailable."))
            }
            return AnyView(CodexTerminalToolView(session: session, isActive: false))
        }
    }
}
