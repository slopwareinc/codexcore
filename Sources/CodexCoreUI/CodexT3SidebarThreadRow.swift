import SwiftUI

// Ported from T3 Code's CURRENT Sidebar.tsx, not LegacySidebar.tsx, at
// 3e6b45028ceec5820dacb37dc3852470ebdc9411.
// Copyright (c) 2026 T3 Tools Inc. MIT; see THIRD_PARTY_NOTICES.md.

enum CodexT3SidebarThreadStatus: Equatable, Sendable {
    case ready, working, waiting, approval, input, limited, failed

    static func resolve(row: CodexSidebarThreadRow) -> Self {
        if let attention = row.attention {
            switch attention {
            case .approval: return .approval
            case .input: return .input
            }
        }
        switch row.liveStatus {
        case .idle: return .ready
        case .running: return .working
        case .failed: return .failed
        }
    }

    func shouldRecede(isActive: Bool, isSelected: Bool, isUnread: Bool) -> Bool {
        if isActive || isSelected || self == .input { return false }
        switch self {
        case .working, .waiting: return true
        case .ready, .approval: return !isUnread
        case .input, .limited, .failed: return false
        }
    }
}

enum CodexT3SidebarThreadRowVariant {
    case card, slim
}

/// The app sidebar has its own CSS scope. Its dark surface and interaction
/// colors differ from the global chat palette and must stay local to navigation.
enum CodexT3SidebarColors {
    static func background(for scheme: ColorScheme) -> Color {
        CodexColorPair(light: 0xFAFAFA, dark: 0x000000).resolved(scheme)
    }
    static func foreground(for scheme: ColorScheme) -> Color {
        CodexColorPair(light: 0x27272A, dark: 0xF1F3F7).resolved(scheme)
    }
    static func secondary(for scheme: ColorScheme) -> Color {
        CodexColorPair(light: 0x71717A, dark: 0xA3A3A3).resolved(scheme)
    }
    static func hover(for scheme: ColorScheme) -> Color {
        scheme == .dark ? foreground(for: scheme).opacity(0.08) : CodexColorPair(0xFCFCFC).resolved(scheme)
    }
    static func active(for scheme: ColorScheme) -> Color {
        scheme == .dark ? foreground(for: scheme).opacity(0.11) : .white
    }
    static func bulkSelected(for scheme: ColorScheme) -> Color {
        scheme == .dark ? foreground(for: scheme).opacity(0.07) : .white
    }
}

/// Flat inbox row: live work keeps its project/status, title, and branch lines;
/// explicitly parked history uses the compact one-line variant. Hover changes
/// only the status slot, so a long title never jumps beneath the pointer.
struct CodexT3SidebarThreadRow: View {
    @Environment(\.codexAgentTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var renamingTitle = ""
    @FocusState private var isFocused: Bool
    @FocusState private var isRenameFocused: Bool

    let row: CodexSidebarThreadRow
    var variant: CodexT3SidebarThreadRowVariant = .card
    var projectTitle: String? = nil
    var branch: String? = nil
    var isWorktree = false
    var status: CodexT3SidebarThreadStatus? = nil
    let onSelect: () -> Void
    let onTogglePin: () -> Void
    let onArchive: () -> Void
    var selectionMode = false
    var onToggleSelection: () -> Void = {}
    var onUnarchive: (() -> Void)? = nil
    var sectionDestinations: [CodexSidebarSectionSummary] = []
    var onMoveChat: (String?) -> Void = { _ in }
    var onRename: ((String) -> Void)? = nil

    var body: some View {
        Group {
            switch variant {
            case .card: cardContent
            case .slim: slimContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowFill, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .opacity(recedes && resolvedStatus == .working && !showsActions ? 0.7 : 1)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: activate)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.return) { if isRenaming { return .ignored }; activate(); return .handled }
        .onKeyPress(.space) { if isRenaming { return .ignored }; activate(); return .handled }
        .onChange(of: isRenameFocused) { _, focused in
            if isRenaming && !focused { commitRename() }
        }
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.colors.accent, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .contextMenu { contextActions.disabled(row.isPendingMutation) }
        .accessibilityElement(children: isRenaming ? .contain : .combine)
        .accessibilityLabel([row.summary.title, projectTitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(statusLabel ?? recencyLabel)
        .help(tooltip)
        .accessibilityHint(tooltip)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(row.isSelected ? .isSelected : [])
        .accessibilityAction(.default, activate)
        .accessibilityActions { contextActions.disabled(row.isPendingMutation) }
        .padding(.vertical, variant == .card ? 2 : 0)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                selectionIndicator
                if let projectTitle {
                    CodexT3ProjectMonogram(projectName: projectTitle)
                    Text(projectTitle)
                        .font(metadataFont.weight(recedes ? .regular : .medium))
                        .foregroundStyle(secondaryColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                pinIndicator
                statusSlot
            }
            .frame(height: 20)

            title
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 20)
                .padding(.top, 4)

            HStack(spacing: 6) {
                if let branch, !branch.isEmpty {
                    if isWorktree {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.system(size: 12))
                            .accessibilityLabel("Worktree")
                    }
                    Text(branch)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(branch)
                }
                Spacer(minLength: 0)
                providerIndicator
            }
            .font(metadataFont)
            .foregroundStyle(secondaryColor.opacity(0.4))
            .frame(height: 16)
            .padding(.top, 2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(height: 78)
    }

    private var slimContent: some View {
        HStack(spacing: 10) {
            selectionIndicator
            if let projectTitle {
                CodexT3ProjectMonogram(projectName: projectTitle)
                    .saturation(showsActions || row.isSelected ? 1 : 0)
                    .opacity(showsActions || row.isSelected ? 1 : 0.4)
            }
            title
            pinIndicator
            Spacer(minLength: 0)
            statusSlot
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    @ViewBuilder private var title: some View {
        if isRenaming {
            TextField("Thread title", text: $renamingTitle)
                .textFieldStyle(.plain)
                .font(theme.fonts.sidebar.chatTitle.font.weight(.medium))
                .foregroundStyle(primaryColor)
                .padding(.horizontal, 4)
                .background(CodexT3SidebarColors.background(for: colorScheme), in: RoundedRectangle(cornerRadius: 2))
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(primaryColor, lineWidth: 1))
                .focused($isRenameFocused)
                .task {
                    // The replacement field must join the responder chain
                    // before it can take focus from the sidebar search field.
                    await Task.yield()
                    guard !Task.isCancelled, isRenaming else { return }
                    isRenameFocused = true
                }
                .onSubmit(commitRename)
                .onKeyPress(.escape) { cancelRename(); return .handled }
                .accessibilityLabel("Thread title")
        } else {
            Text(row.summary.title)
                .font(theme.fonts.sidebar.chatTitle.font.weight(recedes ? .regular : .medium))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .onTapGesture(count: 2, perform: beginRename)
        }
    }

    @ViewBuilder private var selectionIndicator: some View {
        if selectionMode {
            Image(systemName: row.isBulkSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(row.isBulkSelected ? theme.colors.accent : theme.colors.textSecondary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var pinIndicator: some View {
        if row.isPinned {
            if row.canPin && !row.isPendingMutation {
                CodexT3SidebarPinButton(title: row.summary.title, color: secondaryColor, action: onTogglePin)
            } else {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryColor.opacity(0.65))
                    .accessibilityLabel("Pinned")
            }
        }
    }

    private var statusSlot: some View {
        Group {
            if showsActions && hasActions { hoverActions } else { statusContent }
        }
        .frame(minWidth: 32, minHeight: 20, alignment: .trailing)
    }

    private var statusContent: some View {
        HStack(spacing: 4) {
            if row.isPendingMutation {
                CodexSpinner(color: theme.colors.textSecondary, size: .small)
                Text("Updating")
            } else if variant == .card, let statusLabel {
                if resolvedStatus == .working {
                    Circle()
                        .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                        .frame(width: 14, height: 14)
                } else if let statusSymbol {
                    Image(systemName: statusSymbol).font(.system(size: 14))
                }
                Text(statusLabel).fontWeight(.medium)
            } else {
                Text(recencyLabel)
            }
        }
        .font(metadataFont)
        .foregroundStyle(statusColor)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var hoverActions: some View {
        HStack(spacing: 2) {
            if let onUnarchive {
                actionButton("arrow.uturn.backward", label: "Restore chat", action: onUnarchive)
            } else if row.canArchive {
                actionButton("archivebox", label: "Archive chat", action: onArchive)
            }
        }
        .opacity(row.isPendingMutation ? 0.55 : 1)
        .disabled(row.isPendingMutation)
    }

    private func actionButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(secondaryColor)
        .accessibilityLabel("\(label) \(row.summary.title)")
        .help(label)
    }

    @ViewBuilder private var providerIndicator: some View {
        if let provider = row.summary.modelProvider?.nilIfBlank {
            if provider.lowercased() == "openai" || provider.lowercased() == "codex" {
                CodexT3CodexMark()
                    .fill(colorScheme == .dark ? Color.white : Color.black, style: FillStyle(eoFill: true))
                    .frame(width: 14, height: 14)
                    .opacity(0.6)
                    .accessibilityLabel("Codex")
            } else {
                Text(provider)
                    .font(metadataFont)
                    .foregroundStyle(secondaryColor.opacity(0.6))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder private var contextActions: some View {
        if let onUnarchive {
            Button("Restore chat", systemImage: "arrow.uturn.backward", action: onUnarchive)
        } else {
            if row.canPin {
                Button(row.isPinned ? "Unpin chat" : "Pin chat", systemImage: row.isPinned ? "pin.slash" : "pin", action: onTogglePin)
            }
            if row.canArchive { Button("Archive chat", systemImage: "archivebox", action: onArchive) }
            if onRename != nil { Button("Rename chat", systemImage: "pencil", action: beginRename) }
            if !sectionDestinations.isEmpty {
                Menu("Move to section") {
                    ForEach(sectionDestinations) { section in
                        Button(section.name) { onMoveChat(section.id) }
                    }
                    if row.summary.sectionID != nil {
                        Divider()
                        Button("Remove from section") { onMoveChat(nil) }
                    }
                }
            }
            if selectionMode {
                Button(row.isBulkSelected ? "Deselect chat" : "Select chat", action: onToggleSelection)
            }
        }
    }

    private func activate() {
        guard !isRenaming else { return }
        onSelect()
    }

    private func beginRename() {
        guard onRename != nil, !row.isPendingMutation else { return }
        renamingTitle = row.summary.title
        isRenaming = true
    }

    private func commitRename() {
        guard isRenaming else { return }
        let title = renamingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // Finish before focus changes; blur must not send the same edit twice.
        isRenaming = false
        isRenameFocused = false
        guard !title.isEmpty, title != row.summary.title else { return }
        onRename?(title)
    }

    private func cancelRename() {
        isRenaming = false
        isRenameFocused = false
    }

    private var resolvedStatus: CodexT3SidebarThreadStatus { status ?? .resolve(row: row) }
    private var showsActions: Bool { isHovered || isFocused }
    private var hasActions: Bool { onUnarchive != nil || row.canArchive }
    private var recedes: Bool {
        resolvedStatus.shouldRecede(isActive: row.isSelected, isSelected: row.isBulkSelected, isUnread: row.hasUnreadWhileInactive)
    }
    private var metadataFont: Font {
        var token = theme.fonts.sidebar.chatTitle
        token.size = max(8, token.size - 2)
        token.weight = .regular
        return token.font
    }
    private var primaryColor: Color { CodexT3SidebarColors.foreground(for: colorScheme) }
    private var secondaryColor: Color { CodexT3SidebarColors.secondary(for: colorScheme) }
    private var titleColor: Color {
        if showsActions || row.isSelected || resolvedStatus == .input || row.hasUnreadWhileInactive { return primaryColor }
        if recedes { return secondaryColor.opacity(variant == .slim ? 0.7 : 1) }
        return primaryColor.opacity(variant == .slim ? 0.7 : 0.9)
    }
    private var rowFill: Color {
        if row.isSelected {
            return CodexT3SidebarColors.active(for: colorScheme)
        }
        if row.isBulkSelected {
            return CodexT3SidebarColors.bulkSelected(for: colorScheme)
        }
        if showsActions {
            return CodexT3SidebarColors.hover(for: colorScheme)
        }
        return .clear
    }
    private var statusLabel: String? {
        if row.isPendingMutation { return "Updating" }
        switch resolvedStatus {
        case .working: return "Working"
        case .waiting: return "Waiting"
        case .approval: return "Approval"
        case .input: return "Input"
        case .limited: return "Limited"
        case .failed: return "Failed"
        case .ready: return row.hasUnreadWhileInactive ? "Done" : nil
        }
    }
    private var statusSymbol: String? {
        switch resolvedStatus {
        case .approval: "checkmark.shield"
        case .input: "questionmark.bubble"
        case .limited, .failed: "exclamationmark.circle"
        case .ready: row.hasUnreadWhileInactive ? "checkmark.circle" : nil
        case .working, .waiting: nil
        }
    }
    private var statusColor: Color {
        if row.isPendingMutation { return secondaryColor }
        switch resolvedStatus {
        case .working: return CodexColorPair(light: 0x2B7FFF, dark: 0x2B7FFF).resolved(colorScheme)
        case .approval, .limited: return theme.colors.warning
        case .input: return CodexColorPair(light: 0x4F39F6, dark: 0xA3B3FF).resolved(colorScheme)
        case .failed: return theme.colors.danger
        case .ready: return row.hasUnreadWhileInactive ? theme.colors.success : secondaryColor
        case .waiting: return secondaryColor
        }
    }
    private var recencyLabel: String {
        Self.recencyLabel(timestamp: row.summary.recencyAt ?? row.summary.updatedAt ?? row.summary.createdAt, now: Date().timeIntervalSince1970)
    }
    static func recencyLabel(timestamp: TimeInterval?, now: TimeInterval) -> String {
        guard let timestamp, timestamp.isFinite, now.isFinite else { return "" }
        let elapsed = max(0, now - timestamp)
        if elapsed < 60 { return "now" }
        if elapsed < 3_600 { return "\(Int(elapsed / 60))m" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3_600))h" }
        guard elapsed / 86_400 < Double(Int.max) else { return "" }
        return "\(Int(elapsed / 86_400))d"
    }
    private var tooltip: String {
        [row.summary.title, projectTitle, branch, row.statusText, row.summary.modelProvider]
            .compactMap { $0?.nilIfBlank }.joined(separator: "\n")
    }
}

private struct CodexT3SidebarPinButton: View {
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    let title: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isHovered || isFocused ? "pin.slash" : "pin.fill")
                .font(.system(size: 12))
                .foregroundStyle(color.opacity(isHovered || isFocused ? 1 : 0.65))
                .frame(width: 16, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .help("Unpin chat")
        .accessibilityLabel("Unpin chat \(title)")
    }
}
