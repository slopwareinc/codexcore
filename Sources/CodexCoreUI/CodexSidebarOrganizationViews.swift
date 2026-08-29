import Foundation
import SwiftUI

/// Optional instrumentation seam used by mounted-sidebar tests. Appearance
/// counts are scoped by stable section identity, so a sibling update must not
/// look like an unrelated section was remounted.
public final class CodexSidebarMountedRenderCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    public init() {}

    public func record(sectionID: String) {
        lock.withLock { counts[sectionID, default: 0] += 1 }
    }

    public func count(for sectionID: String) -> Int {
        lock.withLock { counts[sectionID, default: 0] }
    }
}

struct CodexSidebarBulkSelectionToolbar: View {
    @Environment(\.codexAgentTheme) private var theme

    let snapshot: CodexSidebarSnapshot
    let onSelectAll: () -> Void
    let onTogglePinned: () -> Void
    let onArchive: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("\(snapshot.selectedThreadIDs.count) selected")
                .font(theme.fonts.sidebar.disclosureTitle.font)
                .foregroundStyle(theme.colors.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Select all", action: onSelectAll)
                .font(theme.fonts.sidebar.hiddenRowsPrompt.font)
                .buttonStyle(.plain)
                .keyboardShortcut("a", modifiers: [.command])
                .accessibilityLabel("Select all chats")
            Button {
                onTogglePinned()
            } label: {
                Image(systemName: "pin")
                    .font(theme.fonts.sidebar.chatActionIcon.font)
            }
            .buttonStyle(.plain)
            .help("Pin or unpin selected chats")
            .accessibilityLabel("Pin or unpin selected chats")
            Button {
                onArchive()
            } label: {
                Image(systemName: "archivebox")
                    .font(theme.fonts.sidebar.chatActionIcon.font)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(snapshot.selectedThreadIDs.isEmpty)
            .help("Archive selected chats")
            .accessibilityLabel("Archive selected chats")
            Button {
                onClear()
            } label: {
                Image(systemName: "xmark")
                    .font(theme.fonts.sidebar.chatActionIcon.font)
            }
            .buttonStyle(.plain)
            .help("Exit selection mode")
            .accessibilityLabel("Exit chat selection mode")
        }
        .padding(.horizontal, 8)
        .frame(height: theme.fonts.sidebar.disclosureRowHeight)
        .background(
            theme.colors.selection.opacity(theme.effects.selectionOpacity),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat selection mode")
    }
}

struct CodexSidebarCustomSectionsView: View {
    @Environment(\.codexAgentTheme) private var theme

    let snapshot: CodexSidebarSnapshot
    let sectionDestinations: [CodexSidebarSectionSummary]
    let onToggleSection: (String) -> Void
    let onSelectChat: (CodexThreadSummary) -> Void
    let onTogglePinChat: (CodexThreadSummary) -> Void
    let onArchiveChat: (CodexThreadSummary) -> Void
    let onToggleThreadSelection: (String) -> Void
    let onMoveChat: (CodexThreadSummary, String?) -> Void
    let renderCounter: CodexSidebarMountedRenderCounter?

    @ViewBuilder
    var body: some View {
        if !snapshot.sections.isEmpty && !snapshot.isCollapsed {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(snapshot.sections) { section in
                    VStack(alignment: .leading, spacing: 2) {
                        SidebarSectionHeader(
                            title: section.section.name,
                            isExpanded: section.isExpanded,
                            attentionState: CodexSidebarAttentionState.aggregate(section.rows),
                            icon: section.section.icon,
                            color: section.section.color
                        ) {
                            onToggleSection(section.id)
                        }
                        if section.isExpanded {
                            if section.rows.isEmpty {
                                Text("No chats in this section")
                                    .font(theme.fonts.sidebar.emptyState.font)
                                    .foregroundStyle(theme.colors.textTertiary)
                                    .padding(.leading, 30)
                                    .padding(.vertical, 5)
                            } else {
                                ForEach(section.rows) { row in
                                    SidebarChatRow(
                                        row: row,
                                        indentation: 0,
                                        showsRecency: true,
                                        onSelect: { onSelectChat(row.summary) },
                                        onTogglePin: { onTogglePinChat(row.summary) },
                                        onArchive: { onArchiveChat(row.summary) },
                                        selectionMode: snapshot.isBulkSelectionMode,
                                        onToggleSelection: { onToggleThreadSelection(row.id) },
                                        sectionDestinations: sectionDestinations,
                                        onMoveChat: { sectionID in onMoveChat(row.summary, sectionID) }
                                    )
                                }
                            }
                        }
                    }
                    .onAppear { renderCounter?.record(sectionID: section.id) }
                }
            }
        }
    }
}

struct CodexSidebarArchivedSectionView: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var showsArchivedChats = false

    let snapshot: CodexSidebarSnapshot
    let onSelectChat: (CodexThreadSummary) -> Void
    let onLoadArchived: () -> Void
    let onLoadMore: () -> Void
    let onUnarchive: (CodexThreadSummary) -> Void
    let renderCounter: CodexSidebarMountedRenderCounter?

    @ViewBuilder
    var body: some View {
        if !snapshot.isCollapsed {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    showsArchivedChats.toggle()
                    if showsArchivedChats && snapshot.archivedLoadState == .idle {
                        onLoadArchived()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showsArchivedChats ? "chevron.down" : "chevron.right")
                            .font(theme.fonts.sidebar.disclosureChevron.font)
                            .frame(width: 14)
                        Image(systemName: "archivebox")
                            .font(theme.fonts.sidebar.chatActionIcon.font)
                        Text("Archived")
                            .font(theme.fonts.sidebar.disclosureTitle.font)
                        if !snapshot.archivedRows.isEmpty {
                            Text("\(snapshot.archivedRows.count)")
                                .font(theme.fonts.sidebar.disclosureCount.font)
                                .foregroundStyle(theme.colors.textTertiary)
                        }
                        Spacer(minLength: 0)
                        if snapshot.archivedLoadState.isLoading {
                            CodexSpinner(color: theme.colors.textTertiary, size: .small)
                        }
                    }
                    .foregroundStyle(theme.colors.textTertiary)
                    .frame(height: theme.fonts.sidebar.disclosureRowHeight)
                    .padding(.horizontal, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(showsArchivedChats ? "Hide" : "Show") archived chats")

                if showsArchivedChats {
                    if let message = snapshot.archivedLoadState.errorMessage {
                        Text(message)
                            .font(theme.fonts.sidebar.emptyState.font)
                            .foregroundStyle(theme.colors.danger)
                            .padding(.leading, 30)
                            .padding(.vertical, 5)
                    } else if snapshot.archivedRows.isEmpty && !snapshot.archivedLoadState.isLoading {
                        Text("No archived chats")
                            .font(theme.fonts.sidebar.emptyState.font)
                            .foregroundStyle(theme.colors.textTertiary)
                            .padding(.leading, 30)
                            .padding(.vertical, 5)
                    }
                    ForEach(snapshot.archivedRows) { row in
                        SidebarChatRow(
                            row: row,
                            indentation: 0,
                            showsRecency: true,
                            onSelect: { onSelectChat(row.summary) },
                            onTogglePin: {},
                            onArchive: {},
                            onUnarchive: { onUnarchive(row.summary) },
                            sectionDestinations: [],
                            onMoveChat: { _ in }
                        )
                    }
                    if snapshot.archivedNextCursor != nil {
                        Button("Load more archived chats", action: onLoadMore)
                            .font(theme.fonts.sidebar.hiddenRowsPrompt.font)
                            .foregroundStyle(theme.colors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 30)
                            .disabled(snapshot.archivedLoadState.isLoading)
                            .accessibilityLabel("Load more archived chats")
                    }
                }
            }
            .onAppear { renderCounter?.record(sectionID: "archived") }
        }
    }
}
