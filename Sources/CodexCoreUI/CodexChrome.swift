import SwiftUI

/// A complete reusable Codex chat workspace: transcript, header, composer, and session sidebar.
public struct CodexChatWorkspaceView: View {
    @Environment(\.codexAgentTheme) private var theme

    private let messages: [CodexChatMessage]
    private let lifecycleEvents: [CodexAgentLifecycleEvent]
    private let sideChat: CodexSideChatState?
    private let subagents: [CodexSubagentState]
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
    @State private var isAgentPanelOpen = false
    @State private var selectedPanelTabID: String?

    public init(
        messages: [CodexChatMessage],
        lifecycleEvents: [CodexAgentLifecycleEvent] = [],
        sideChat: CodexSideChatState? = nil,
        subagents: [CodexSubagentState] = [],
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
        self.lifecycleEvents = lifecycleEvents
        self.sideChat = sideChat
        self.subagents = subagents
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
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 0) {
                mainColumn

                if isAgentPanelOpen, !panelTabs.isEmpty {
                    CodexAgentSidePanel(
                        tabs: panelTabs,
                        selectedTabID: $selectedPanelTabID,
                        onClose: { withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { isAgentPanelOpen = false } }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }

            CodexFloatingSummaryPanel(
                sideChat: sideChat,
                subagents: subagents,
                onSelectTab: openPanelTab
            )
            .padding(.top, 58)
            .padding(.trailing, isAgentPanelOpen ? theme.spacing.sidePanelWidth + 16 : 16)
            .animation(.spring(response: 0.32, dampingFraction: 0.9), value: isAgentPanelOpen)
        }
        .background(theme.colors.canvas.opacity(0.001))
    }

    private var mainColumn: some View {
        ZStack(alignment: .top) {
            CodexTranscriptView(messages: messages, lifecycleEvents: lifecycleEvents) {
                CodexEmptyTranscriptView { prompt in
                    if let onPromptSelected {
                        onPromptSelected(prompt)
                    } else {
                        draft = prompt
                    }
                }
            }
            .safeAreaPadding(.top, 58)
            .safeAreaPadding(.bottom, 122)

            VStack(spacing: 0) {
                CodexChatHeader(
                    workspacePath: workspacePath,
                    connectionState: connectionState,
                    activities: activities,
                    hasPanelTabs: !panelTabs.isEmpty,
                    isPanelOpen: isAgentPanelOpen,
                    onTogglePanel: toggleAgentPanel,
                    onDisconnect: onDisconnect
                )
                .codexGlass(RoundedRectangle(cornerRadius: theme.radii.panel, style: .continuous))
                .padding(.horizontal, 14)
                .padding(.top, 8)

                Spacer(minLength: 0)
                CodexComposerBar(
                    draft: $draft,
                    isSending: isSending,
                    canSend: canSend,
                    onSend: onSend,
                    onInterrupt: onInterrupt
                )
                .frame(maxWidth: theme.spacing.composerMaxWidth + 32)
                .codexGlass(RoundedRectangle(cornerRadius: theme.radii.composer, style: .continuous))
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
        .frame(minWidth: 540)
    }

    private var panelTabs: [CodexAgentPanelTab] {
        var tabs: [CodexAgentPanelTab] = []
        if let sideChat { tabs.append(.sideChat(sideChat)) }
        tabs.append(contentsOf: subagents.map(CodexAgentPanelTab.subagent))
        return tabs
    }

    private func openPanelTab(_ id: String) {
        selectedPanelTabID = id
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
            isAgentPanelOpen = true
        }
    }

    private func toggleAgentPanel() {
        if selectedPanelTabID == nil { selectedPanelTabID = panelTabs.first?.id }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
            isAgentPanelOpen.toggle()
        }
    }
}

public struct CodexChatHeader: View {
    @Environment(\.codexAgentTheme) private var theme

    private let workspacePath: String
    private let connectionState: CodexConnectionState
    private let activities: [CodexActivity]
    private let hasPanelTabs: Bool
    private let isPanelOpen: Bool
    private let onTogglePanel: () -> Void
    private let onDisconnect: () -> Void

    public init(
        workspacePath: String,
        connectionState: CodexConnectionState,
        activities: [CodexActivity] = [],
        hasPanelTabs: Bool = false,
        isPanelOpen: Bool = false,
        onTogglePanel: @escaping () -> Void = {},
        onDisconnect: @escaping () -> Void
    ) {
        self.workspacePath = workspacePath
        self.connectionState = connectionState
        self.activities = activities
        self.hasPanelTabs = hasPanelTabs
        self.isPanelOpen = isPanelOpen
        self.onTogglePanel = onTogglePanel
        self.onDisconnect = onDisconnect
    }

    public var body: some View {
        HStack(spacing: 10) {
            CodexBrandMark(size: 28)

            VStack(alignment: .leading, spacing: 0) {
                Text("Codex")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                    Text(shortPath(workspacePath))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textTertiary)
            }

            Spacer()

            if let latest = activities.first {
                Text(latest.title)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .trailing)
            }

            CodexStatusPill(state: connectionState)

            Button(action: onTogglePanel) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hasPanelTabs ? theme.colors.textSecondary : theme.colors.textTertiary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .codexGlass(Circle(), interactive: true)
            .disabled(!hasPanelTabs)
            .help("Toggle agent panel")

            Button(action: onDisconnect) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.colors.textSecondary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .codexGlass(Circle(), interactive: true)
            .help("Disconnect")
        }
        .frame(height: theme.spacing.toolbarHeight)
        .padding(.horizontal, 12)
    }

    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }
}

public struct CodexStatusPill: View {
    @Environment(\.codexAgentTheme) private var theme

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
                .font(theme.fonts.caption.weight(.medium))
                .foregroundStyle(theme.colors.textSecondary)
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
        case .disconnected: return theme.colors.textTertiary
        case .connecting: return theme.colors.warning
        case .connected: return theme.colors.success
        case .failed: return theme.colors.danger
        }
    }
}

public struct CodexComposerBar: View {
    @Environment(\.codexAgentTheme) private var theme

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
                    .font(theme.fonts.chat)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit(onSend)
                    .padding(.leading, 6)
                    .padding(.vertical, 6)

                if isSending {
                    Button(action: onInterrupt) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.colors.danger)
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
            .background(theme.colors.surfaceSunken.opacity(0.50), in: RoundedRectangle(cornerRadius: theme.radii.composer - 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radii.composer - 7, style: .continuous)
                    .stroke(theme.colors.border, lineWidth: 1)
            )

            HStack(spacing: 14) {
                CapabilityTag(icon: "square.and.pencil", text: "workspace-write")
                CapabilityTag(icon: "checkmark.seal.fill", text: "auto-review")
                Spacer()
                Text("Cmd+Return to send")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
            }
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .onAppear { focused = true }
    }
}

private struct SendButton: View {
    @Environment(\.codexAgentTheme) private var theme

    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(enabled ? theme.colors.onAccent : theme.colors.textTertiary)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .background {
            if enabled {
                Circle().fill(theme.colors.accent)
            } else {
                Circle().fill(theme.colors.surfaceSunken)
            }
        }
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(!enabled)
        .animation(.snappy(duration: 0.2), value: enabled)
    }
}

private struct CapabilityTag: View {
    @Environment(\.codexAgentTheme) private var theme

    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9.5))
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(theme.colors.textTertiary)
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
