import AppKit
import SwiftUI

struct CodexT3SidebarInboxActions {
    var newChat: () -> Void
    var newProject: () -> Void
    var startProjectChat: (String) -> Void
    var selectChat: (CodexThreadSummary) -> Void
    var togglePin: (CodexThreadSummary) -> Void
    var archive: (CodexThreadSummary) -> Void
    var unarchive: (CodexThreadSummary) -> Void
    var rename: ((CodexThreadSummary, String) -> Void)?
    var toggleSelection: (String) -> Void
    var clearSelection: () -> Void
    var moveToSection: (CodexThreadSummary, String?) -> Void
    var loadArchived: () -> Void
    var loadMoreArchived: () -> Void
    var loadMoreActive: () -> Void
    var search: ((String) async -> Void)?
    var loadMoreSearch: (() -> Void)?
}

/// T3's current flat inbox. It never flattens the native tree's five-row
/// previews, or mistakes a completed run for a settled thread.
struct CodexT3SidebarInboxView: View {
    @Environment(\.codexAgentTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var localProjectScopeID: String?
    @State private var searchQuery = ""
    @State private var activeSearchIndex = 0
    @State private var isArchiveExpanded = false
    @State private var archivedVisibleCount = 10
    @State private var selectionAnchorID: String?
    @State private var isNewChatPickerPresented = false
    @State private var projectionCache = CodexT3SidebarInboxProjectionCache()
    @FocusState private var isSearchFocused: Bool

    let snapshot: CodexSidebarSnapshot
    var projectScope: Binding<String?>?
    var isProjectCatalogReady = false
    var searchState: CodexSidebarInboxSearchState?
    var hasMoreActive = false
    var isLoadingMoreActive = false
    var sectionDestinations: [CodexSidebarSectionSummary] = []
    let actions: CodexT3SidebarInboxActions
    var bulkSelectionToolbar: ((CodexSidebarSnapshot, [String]) -> AnyView)?

    private var scope: Binding<String?> { projectScope ?? $localProjectScopeID }
    private var projection: CodexT3SidebarInboxProjection { projectionCache.value(snapshot: snapshot, scopeID: scope.wrappedValue) }
    private var normalizedQuery: String { searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearching: Bool { !normalizedQuery.isEmpty }
    private var matches: [CodexThreadSearchResult] {
        projection.searchResults(searchState, query: normalizedQuery, projectScopeID: scope.wrappedValue)
    }
    private var secondary: Color { CodexT3SidebarColors.secondary(for: colorScheme) }

    var body: some View {
        VStack(spacing: 8) {
            header.padding(.horizontal, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if let error = snapshot.actionErrorMessage {
                        notice(error, color: theme.colors.danger)
                    }
                    if snapshot.isBulkSelectionMode, let bulkSelectionToolbar {
                        bulkSelectionToolbar(snapshot, projection.allActive.map(\.id))
                    }
                    if isSearching { searchResults }
                    else { inbox }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
        }
        .task(id: searchQuery) {
            guard let search = actions.search else { return }
            if !normalizedQuery.isEmpty {
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await search(normalizedQuery)
        }
        .onChange(of: searchQuery) { _, _ in
            activeSearchIndex = 0
            selectionAnchorID = nil
            actions.clearSelection()
        }
        .onChange(of: scope.wrappedValue) { _, _ in
            archivedVisibleCount = 10
            activeSearchIndex = 0
            selectionAnchorID = nil
            actions.clearSelection()
        }
        .onChange(of: isProjectCatalogReady, initial: true) { _, _ in reconcileScope() }
        .onChange(of: projection.projects.map(\.id)) { _, _ in reconcileScope() }
    }

    private var header: some View {
        HStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 14)).accessibilityHidden(true)
                TextField("Search", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(theme.fonts.body.weight(.medium))
                    .focused($isSearchFocused)
                    .accessibilityLabel("Search chats")
                    .onSubmit(openHighlightedSearchResult)
                    .onKeyPress(.downArrow) { moveSearchHighlight(1); return isSearching ? .handled : .ignored }
                    .onKeyPress(.upArrow) { moveSearchHighlight(-1); return isSearching ? .handled : .ignored }
                    .onKeyPress(.escape) { searchQuery = ""; return .handled }
                if isSearching {
                    headerButton("xmark", label: "Clear chat search") { searchQuery = ""; isSearchFocused = true }
                        .frame(width: 16)
                }
            }
            .foregroundStyle(secondary)
            .padding(.horizontal, 8)
            .frame(height: 32)
            if !projection.projects.isEmpty {
                projectScopePicker
                headerButton("folder.badge.plus", label: "Add project", action: actions.newProject)
            }
            headerButton("square.and.pencil", label: "New chat (⌘N); Shift-click for the current project", action: startNewChat)
                .popover(isPresented: $isNewChatPickerPresented, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("New chat").font(theme.fonts.label).padding(.bottom, 4)
                        ForEach(projection.projects) { project in
                            Button {
                                isNewChatPickerPresented = false
                                actions.startProjectChat(project.id)
                            } label: {
                                HStack(spacing: 8) {
                                    CodexT3ProjectMonogram(projectName: project.displayName)
                                    Text(project.displayName).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .frame(minHeight: 28).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        Divider()
                        Button("Projectless chat") { isNewChatPickerPresented = false; actions.newChat() }
                            .buttonStyle(.plain).frame(minHeight: 28)
                    }
                    .font(theme.fonts.body).padding(12).frame(width: 240)
                    .codexAgentTheme(theme)
                }
        }
    }

    private var projectScopePicker: some View {
        Menu {
            Button { scope.wrappedValue = nil } label: {
                Label("All projects", systemImage: scope.wrappedValue == nil ? "checkmark" : "square.grid.2x2")
            }
            Divider()
            ForEach(projection.projects) { project in
                Button { scope.wrappedValue = project.id } label: {
                    Label(project.displayName, systemImage: scope.wrappedValue == project.id ? "checkmark" : "folder")
                }
            }
        } label: {
            Group {
                if let selected = projection.projects.first(where: { $0.id == scope.wrappedValue }) {
                    CodexT3ProjectMonogram(projectName: selected.displayName)
                } else { Image(systemName: "square.grid.2x2").font(.system(size: 14)) }
            }
            .frame(width: 28, height: 28)
            .foregroundStyle(secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Filter chats by project")
        .accessibilityValue(projection.projects.first(where: { $0.id == scope.wrappedValue })?.displayName ?? "All projects")
        .help("Filter chats by project")
    }

    @ViewBuilder private var inbox: some View {
        ForEach(projection.pinned) { item in chatRow(item) }
        if !projection.pinned.isEmpty && !projection.active.isEmpty {
            Rectangle().fill(secondary.opacity(0.12)).frame(height: 1).padding(.vertical, 6).padding(.horizontal, 10)
        }
        ForEach(projection.active) { item in chatRow(item) }
        if projection.allActive.isEmpty {
            notice(snapshot.activeLoadState.isLoading ? "Loading chats…" : "No chats", color: secondary)
        }
        if hasMoreActive {
            Button(isLoadingMoreActive ? "Loading chats…" : "Load older chats", action: actions.loadMoreActive)
                .buttonStyle(.plain).font(theme.fonts.caption).foregroundStyle(secondary)
                .disabled(isLoadingMoreActive).padding(.horizontal, 10).padding(.vertical, 8)
        }
        archivedShelf
    }

    @ViewBuilder private var archivedShelf: some View {
        Button {
            isArchiveExpanded.toggle()
            if isArchiveExpanded { actions.loadArchived() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isArchiveExpanded ? 90 : 0))
                Text("Archived").font(theme.fonts.caption)
                Rectangle().fill(secondary.opacity(0.18)).frame(height: 1)
            }
            .foregroundStyle(secondary.opacity(0.8)).frame(height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.horizontal, 10).padding(.top, 12)
        .accessibilityLabel(isArchiveExpanded ? "Collapse archived chats" : "Show archived chats")
        let visible = CodexT3SidebarInboxProjection.archivedPage(projection.archived, visibleCount: archivedVisibleCount,
                                                               selectedID: snapshot.selectedThreadID, expanded: isArchiveExpanded)
        ForEach(visible) { item in chatRow(item, variant: .slim) }
        if isArchiveExpanded {
            if snapshot.archivedLoadState.isLoading { notice("Loading archived chats…", color: secondary) }
            else if let error = snapshot.archivedLoadState.errorMessage { notice(error, color: theme.colors.danger) }
            else if projection.archived.isEmpty { notice("No archived chats", color: secondary) }
            if projection.archived.count > visible.count {
                Button("Show more archived chats") { archivedVisibleCount += 25 }
                    .buttonStyle(.plain).font(theme.fonts.caption).foregroundStyle(secondary).padding(10)
            } else if snapshot.archivedNextCursor != nil {
                Button("Load older archived chats", action: actions.loadMoreArchived)
                    .buttonStyle(.plain).font(theme.fonts.caption).foregroundStyle(secondary).padding(10)
            }
        }
    }

    private func chatRow(_ item: CodexT3SidebarInboxItem, variant: CodexT3SidebarThreadRowVariant = .card) -> some View {
        CodexT3SidebarThreadRow(
            row: item.row, variant: variant, projectTitle: item.project?.displayName,
            branch: item.row.summary.gitBranch,
            isWorktree: CodexProjectSidebarEnvironmentLabel.title(workspacePath: item.row.summary.workspacePath) != nil,
            onSelect: { select(item) }, onTogglePin: { actions.togglePin(item.row.summary) },
            onArchive: { actions.archive(item.row.summary) },
            selectionMode: snapshot.isBulkSelectionMode,
            onToggleSelection: { actions.toggleSelection(item.id) },
            onUnarchive: item.row.isArchived ? { actions.unarchive(item.row.summary) } : nil,
            sectionDestinations: sectionDestinations,
            onMoveChat: { actions.moveToSection(item.row.summary, $0) },
            onRename: actions.rename.map { rename in { rename(item.row.summary, $0) } }
        )
    }

    @ViewBuilder private var searchResults: some View {
        if let state = searchState, state.query == normalizedQuery, state.isSearching {
            notice("Searching…", color: secondary)
        }
        if let state = searchState, state.query == normalizedQuery, let error = state.errorMessage {
            notice(error, color: theme.colors.danger)
        }
        ForEach(Array(matches.enumerated()), id: \.element.id) { index, result in
            Button { actions.selectChat(result.thread); isSearchFocused = false } label: {
                HStack(alignment: .top, spacing: 10) {
                    if let project = projection.project(for: result.thread) { CodexT3ProjectMonogram(projectName: project.displayName) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.thread.title).font(theme.fonts.body.weight(.medium)).lineLimit(1)
                        if !result.snippet.isEmpty && result.snippet != result.thread.title {
                            Text(result.snippet).font(theme.fonts.caption).foregroundStyle(secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(CodexT3SidebarColors.foreground(for: colorScheme))
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(index == activeSearchIndex ? CodexT3SidebarColors.active(for: colorScheme) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).onHover { if $0 { activeSearchIndex = index } }
        }
        if matches.isEmpty && searchState?.isSearching != true { notice("No matching chats", color: secondary) }
        if searchState?.query == normalizedQuery && searchState?.hasMoreResults == true, let more = actions.loadMoreSearch {
            Button("Load more results", action: more).buttonStyle(.plain).font(theme.fonts.caption).foregroundStyle(secondary).padding(10)
        }
    }

    private func select(_ item: CodexT3SidebarInboxItem) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let visibleIDs = projection.allActive.map(\.id) + CodexT3SidebarInboxProjection.archivedPage(
            projection.archived, visibleCount: archivedVisibleCount, selectedID: snapshot.selectedThreadID, expanded: isArchiveExpanded
        ).map(\.id)
        switch CodexT3SidebarSelectionIntent.resolve(clickedID: item.id, visibleIDs: visibleIDs, selectedIDs: snapshot.selectedThreadIDs,
                                                    anchorID: selectionAnchorID, commandPressed: flags.contains(.command),
                                                    shiftPressed: flags.contains(.shift), selectionMode: snapshot.isBulkSelectionMode) {
        case .navigate: actions.selectChat(item.row.summary)
        case .toggle(let id): actions.toggleSelection(id)
        case .addRange(let ids): ids.forEach(actions.toggleSelection)
        }
        if !flags.contains(.shift) { selectionAnchorID = item.id }
    }

    private func reconcileScope() {
        guard isProjectCatalogReady, let id = scope.wrappedValue, !projection.projects.contains(where: { $0.id == id }) else { return }
        scope.wrappedValue = nil
    }

    private func startNewChat() {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true,
           let id = projection.allActive.first(where: { $0.row.isSelected })?.project?.id {
            actions.startProjectChat(id)
        } else if let id = scope.wrappedValue {
            actions.startProjectChat(id)
        } else if projection.projects.count == 1, let project = projection.projects.first {
            actions.startProjectChat(project.id)
        } else if !projection.projects.isEmpty {
            isNewChatPickerPresented = true
        } else { actions.newChat() }
    }

    private func moveSearchHighlight(_ delta: Int) {
        guard !matches.isEmpty else { return }
        activeSearchIndex = min(max(0, activeSearchIndex + delta), matches.count - 1)
    }

    private func openHighlightedSearchResult() {
        guard isSearching, matches.indices.contains(activeSearchIndex) else { return }
        actions.selectChat(matches[activeSearchIndex].thread)
        isSearchFocused = false
    }

    private func headerButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(secondary).accessibilityLabel(label).help(label)
    }

    private func notice(_ text: String, color: Color) -> some View {
        Text(text).font(theme.fonts.caption).foregroundStyle(color).padding(.horizontal, 10).padding(.vertical, 8)
    }
}
