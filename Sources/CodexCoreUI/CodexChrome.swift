import SwiftUI

/// A complete reusable Codex chat workspace: transcript, header, composer, and session sidebar.
public struct CodexChatWorkspaceView: View {
    private let messages: [CodexChatMessage]
    private let activities: [CodexActivity]
    private let connectionState: CodexConnectionState
    private let workspacePath: String
    private let serverName: String?
    private let authLabel: String
    private let isAuthenticated: Bool
    private let isThreadReady: Bool
    @Binding private var draft: String
    private let isSending: Bool
    private let canSend: Bool
    private let onSend: () -> Void
    private let onInterrupt: () -> Void
    private let onDisconnect: () -> Void
    private let onPromptSelected: ((String) -> Void)?

    public init(
        messages: [CodexChatMessage],
        activities: [CodexActivity],
        connectionState: CodexConnectionState,
        workspacePath: String,
        serverName: String? = nil,
        authLabel: String,
        isAuthenticated: Bool,
        isThreadReady: Bool,
        draft: Binding<String>,
        isSending: Bool,
        canSend: Bool,
        onSend: @escaping () -> Void,
        onInterrupt: @escaping () -> Void,
        onDisconnect: @escaping () -> Void,
        onPromptSelected: ((String) -> Void)? = nil
    ) {
        self.messages = messages
        self.activities = activities
        self.connectionState = connectionState
        self.workspacePath = workspacePath
        self.serverName = serverName
        self.authLabel = authLabel
        self.isAuthenticated = isAuthenticated
        self.isThreadReady = isThreadReady
        self._draft = draft
        self.isSending = isSending
        self.canSend = canSend
        self.onSend = onSend
        self.onInterrupt = onInterrupt
        self.onDisconnect = onDisconnect
        self.onPromptSelected = onPromptSelected
    }

    public var body: some View {
        HStack(spacing: 0) {
            mainColumn
            sidebar
        }
        .padding(14)
    }

    private var mainColumn: some View {
        ZStack(alignment: .top) {
            CodexTranscriptView(messages: messages) {
                CodexEmptyTranscriptView { prompt in
                    if let onPromptSelected {
                        onPromptSelected(prompt)
                    } else {
                        draft = prompt
                    }
                }
            }
            .safeAreaPadding(.top, 66)
            .safeAreaPadding(.bottom, 116)

            VStack(spacing: 0) {
                glassBar {
                    CodexChatHeader(
                        workspacePath: workspacePath,
                        connectionState: connectionState,
                        onDisconnect: onDisconnect
                    )
                }
                Spacer(minLength: 0)
                glassBar {
                    CodexComposerBar(
                        draft: $draft,
                        isSending: isSending,
                        canSend: canSend,
                        onSend: onSend,
                        onInterrupt: onInterrupt
                    )
                }
            }
        }
        .frame(minWidth: 540)
    }

    private var sidebar: some View {
        CodexSessionSidebar(
            serverName: serverName,
            workspacePath: workspacePath,
            authLabel: authLabel,
            isAuthenticated: isAuthenticated,
            isThreadReady: isThreadReady,
            activities: activities
        )
        .frame(width: 304)
        .codexGlass(RoundedRectangle(cornerRadius: CodexTheme.Radius.xl, style: .continuous))
        .padding(.leading, 14)
    }

    private func glassBar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .codexGlass(RoundedRectangle(cornerRadius: CodexTheme.Radius.xl, style: .continuous))
    }
}

public struct CodexChatHeader: View {
    private let workspacePath: String
    private let connectionState: CodexConnectionState
    private let onDisconnect: () -> Void

    public init(
        workspacePath: String,
        connectionState: CodexConnectionState,
        onDisconnect: @escaping () -> Void
    ) {
        self.workspacePath = workspacePath
        self.connectionState = connectionState
        self.onDisconnect = onDisconnect
    }

    public var body: some View {
        HStack(spacing: 12) {
            CodexBrandMark(size: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text("Codex")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CodexTheme.primary)
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                    Text(shortPath(workspacePath))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.tertiary)
            }

            Spacer()

            CodexStatusPill(state: connectionState)

            Button(action: onDisconnect) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CodexTheme.secondary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .codexGlass(Circle(), interactive: true)
            .help("Disconnect")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }
}

public struct CodexStatusPill: View {
    private let state: CodexConnectionState

    public init(state: CodexConnectionState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .overlay(
                    Circle().fill(color).frame(width: 7, height: 7)
                        .opacity(isLive ? 0.6 : 0)
                        .scaleEffect(isLive ? 2.4 : 1)
                        .animation(isLive ? .easeOut(duration: 1.4).repeatForever(autoreverses: false) : .default, value: isLive)
                )
            Text(state.label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(CodexTheme.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .codexGlass(Capsule())
    }

    private var isLive: Bool {
        if case .connected = state { return true }
        return false
    }

    private var color: Color {
        switch state {
        case .disconnected: return CodexTheme.tertiary
        case .connecting: return CodexTheme.warning
        case .connected: return CodexTheme.success
        case .failed: return CodexTheme.danger
        }
    }
}

public struct CodexComposerBar: View {
    @Binding private var draft: String
    private let isSending: Bool
    private let canSend: Bool
    private let onSend: () -> Void
    private let onInterrupt: () -> Void
    @FocusState private var focused: Bool

    public init(
        draft: Binding<String>,
        isSending: Bool,
        canSend: Bool,
        onSend: @escaping () -> Void,
        onInterrupt: @escaping () -> Void
    ) {
        self._draft = draft
        self.isSending = isSending
        self.canSend = canSend
        self.onSend = onSend
        self.onInterrupt = onInterrupt
    }

    public var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask Codex anything about this workspace...", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(CodexTheme.primary)
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit(onSend)
                    .padding(.leading, 6)
                    .padding(.vertical, 6)

                if isSending {
                    Button(action: onInterrupt) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(CodexTheme.danger)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .codexGlass(Circle(), interactive: true)
                    .help("Interrupt")
                } else {
                    SendButton(enabled: canSend, action: onSend)
                }
            }
            .padding(8)
            .background(CodexTheme.surfaceSunken.opacity(0.5), in: RoundedRectangle(cornerRadius: CodexTheme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CodexTheme.Radius.lg, style: .continuous)
                    .stroke(CodexTheme.stroke, lineWidth: 1)
            )

            HStack(spacing: 14) {
                CapabilityTag(icon: "square.and.pencil", text: "workspace-write")
                CapabilityTag(icon: "checkmark.seal.fill", text: "auto-review")
                Spacer()
                Text("Cmd+Return to send")
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.tertiary)
            }
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .onAppear { focused = true }
    }
}

private struct SendButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(enabled ? CodexTheme.onAccent : CodexTheme.tertiary)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .background {
            if enabled {
                Circle().fill(CodexTheme.accent)
            } else {
                Circle().fill(CodexTheme.surfaceSunken)
            }
        }
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(!enabled)
        .animation(.snappy(duration: 0.2), value: enabled)
    }
}

private struct CapabilityTag: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9.5))
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(CodexTheme.tertiary)
    }
}

public struct CodexSessionSidebar: View {
    private let serverName: String?
    private let workspacePath: String
    private let authLabel: String
    private let isAuthenticated: Bool
    private let isThreadReady: Bool
    private let activities: [CodexActivity]

    public init(
        serverName: String?,
        workspacePath: String,
        authLabel: String,
        isAuthenticated: Bool,
        isThreadReady: Bool,
        activities: [CodexActivity]
    ) {
        self.serverName = serverName
        self.workspacePath = workspacePath
        self.authLabel = authLabel
        self.isAuthenticated = isAuthenticated
        self.isThreadReady = isThreadReady
        self.activities = activities
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CodexTheme.Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SESSION")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(CodexTheme.tertiary)
                Text(serverName ?? "Codex")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CodexTheme.primary)
            }

            VStack(spacing: 8) {
                SidebarFact(icon: "folder.fill", title: "Workspace", value: workspacePath, mono: true)
                SidebarFact(icon: "person.badge.key.fill", title: "Auth", value: isAuthenticated ? authLabel : "Sign-in required")
                SidebarFact(icon: "bubble.left.and.text.bubble.right.fill", title: "Thread", value: isThreadReady ? "Ready" : "Preparing...")
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("RECENT ACTIVITY")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(CodexTheme.tertiary)

                if activities.isEmpty {
                    Text("Activity appears here while Codex works.")
                        .font(.system(size: 12))
                        .foregroundStyle(CodexTheme.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView(showsIndicators: false) {
                        CodexActivityTimeline(activities: Array(activities.prefix(14)))
                    }
                }
            }
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct SidebarFact: View {
    let icon: String
    let title: String
    let value: String
    var mono = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.accent)
                .frame(width: 16, height: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CodexTheme.secondary)
                Text(value)
                    .font(.system(size: 11.5, design: mono ? .monospaced : .default))
                    .foregroundStyle(CodexTheme.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodexTheme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: CodexTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.Radius.md, style: .continuous)
                .stroke(CodexTheme.stroke, lineWidth: 1)
        )
    }
}

public struct CodexActivityTimeline: View {
    private let activities: [CodexActivity]

    public init(activities: [CodexActivity]) {
        self.activities = activities
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(activities.enumerated()), id: \.element.id) { index, activity in
                ActivityRow(
                    activity: activity,
                    isFirst: index == 0,
                    isLast: index == activities.count - 1
                )
            }
        }
    }
}

private struct ActivityRow: View {
    let activity: CodexActivity
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : CodexTheme.stroke)
                    .frame(width: 1.5, height: 8)
                ZStack {
                    Circle()
                        .fill(activity.kind.tint.opacity(0.16))
                        .frame(width: 22, height: 22)
                    Image(systemName: activity.kind.systemImage)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(activity.kind.tint)
                }
                Rectangle()
                    .fill(isLast ? Color.clear : CodexTheme.stroke)
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(activity.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CodexTheme.primary)
                    Spacer(minLength: 0)
                    Text(activity.createdAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .font(.system(size: 10))
                        .foregroundStyle(CodexTheme.tertiary)
                        .lineLimit(1)
                }
                if !activity.detail.isEmpty {
                    Text(activity.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(CodexTheme.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, isLast ? 0 : 12)
        }
    }
}
