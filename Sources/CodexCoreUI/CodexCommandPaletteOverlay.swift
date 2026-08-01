import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

public struct CodexCommandPaletteOverlay: View {
    @Environment(\.codexAgentTheme) private var theme

    public let commandRows: [CodexCommandPaletteRow]
    public let searchResults: [CodexThreadSearchResult]
    public let isSearchingChats: Bool
    public let searchErrorMessage: String?
    public let onClose: () -> Void
    public let onSearchChats: (String) async -> Void
    public let onClearSearchResults: () -> Void
    public let onSelectChat: (CodexThreadSearchResult) -> Void
    public let onSelectCommand: (CodexCommandPaletteAction) -> Void

    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var navigation = CodexCommandPaletteNavigationState()
    @FocusState private var isFocused: Bool

    public init(
        commandRows: [CodexCommandPaletteRow] = CodexCommandPaletteModel.defaultCommandRows,
        searchResults: [CodexThreadSearchResult],
        isSearchingChats: Bool,
        searchErrorMessage: String?,
        onClose: @escaping () -> Void,
        onSearchChats: @escaping (String) async -> Void,
        onClearSearchResults: @escaping () -> Void,
        onSelectChat: @escaping (CodexThreadSearchResult) -> Void,
        onSelectCommand: @escaping (CodexCommandPaletteAction) -> Void
    ) {
        self.commandRows = commandRows
        self.searchResults = searchResults
        self.isSearchingChats = isSearchingChats
        self.searchErrorMessage = searchErrorMessage
        self.onClose = onClose
        self.onSearchChats = onSearchChats
        self.onClearSearchResults = onClearSearchResults
        self.onSelectChat = onSelectChat
        self.onSelectCommand = onSelectCommand
    }

    public var body: some View {
        palette
            .padding(.top, 72)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .codexScrim(onTap: onClose)
            .onAppear {
                reconcileNavigation()
                focusSearchField()
            }
            .onDisappear {
                searchTask?.cancel()
                isFocused = false
                onClearSearchResults()
            }
            .onExitCommand(perform: onClose)
            #if canImport(AppKit)
            .background(
                CommandPaletteKeyMonitor(
                    onEscape: onClose,
                    onNavigate: navigate,
                    onSelect: activateSelection
                )
            )
            #endif
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Command menu")
            .accessibilityHint("Use the arrow keys to move and Return to select.")
    }

    private var palette: some View {
        VStack(alignment: .leading, spacing: 13) {
            header
            searchField
            content
        }
        .padding(14)
        .frame(width: 620, height: 540, alignment: .top)
        .codexGlass(
            RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous),
            role: .panel
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Command menu")
                    .font(theme.fonts.sheetTitle)
                    .foregroundStyle(theme.colors.textPrimary)
                Text("Search commands and past chats.")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(theme.fonts.micro)
                    .foregroundStyle(theme.colors.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close command menu")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(theme.fonts.caption.weight(.medium))
                .foregroundStyle(theme.colors.textTertiary)
            TextField("Search chats or run a command", text: $query)
                .textFieldStyle(.plain)
                .font(theme.fonts.chat)
                .foregroundStyle(theme.colors.textPrimary)
                .focused($isFocused)
                .accessibilityLabel("Search chats or run a command")
                .accessibilityValue(query)
                .onSubmit { activateSelection() }
            if isSearchingChats {
                CodexSpinner(size: .small)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 40)
        .background(theme.colors.surfaceElevated.opacity(0.82), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
        .onChange(of: query) { _, value in
            searchTask?.cancel()
            reconcileNavigation()
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                onClearSearchResults()
                return
            }
            searchTask = Task {
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
                await onSearchChats(trimmed)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let paletteModel = CodexCommandPaletteModel(
            query: query,
            commandRows: commandRows,
            chatResults: searchResults,
            isLoading: isSearchingChats,
            errorMessage: searchErrorMessage
        )

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let statusTitle = paletteModel.status.title {
                        statusRow(statusTitle, isError: isErrorStatus(paletteModel.status))
                    }

                    ForEach(paletteModel.sections) { section in
                        sectionView(section)
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: navigation.selectedRowID) { _, rowID in
                guard let rowID else { return }
                withAnimation(.easeOut(duration: theme.animations.snappyDuration)) {
                    proxy.scrollTo(rowID, anchor: .center)
                }
            }
            .onChange(of: searchResults) { _, _ in
                reconcileNavigation()
            }
            .onChange(of: isSearchingChats) { _, _ in
                reconcileNavigation()
            }
        }
    }

    private func sectionView(_ section: CodexCommandPaletteSection) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(section.title)
                .font(theme.fonts.caption.weight(.semibold))
                .foregroundStyle(theme.colors.textTertiary)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)

            if section.rows.isEmpty {
                emptyCategoryRow(section.title)
            } else {
                ForEach(section.rows) { row in
                    rowButton(row)
                }
            }
        }
    }

    private func rowButton(_ row: CodexCommandPaletteRow) -> some View {
        PaletteRowButton(
            row: row,
            isSelected: navigation.selectedRowID == row.id,
            select: select,
            onHover: { isHovered in
                guard isHovered else { return }
                navigation = CodexCommandPaletteNavigationState(selectedRowID: row.id)
            }
        )
        .id(row.id)
    }

    private func emptyCategoryRow(_ title: String) -> some View {
        Text(title == "Chats" ? "Search past chats by title, project, or transcript." : "No quick actions")
            .font(theme.fonts.caption)
            .foregroundStyle(theme.colors.textTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                theme.colors.hover.opacity(theme.effects.hoverOpacity * 0.5),
                in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
            )
    }

    private func statusRow(_ title: String, isError: Bool) -> some View {
        Text(title)
            .font(theme.fonts.caption)
            .foregroundStyle(isError ? theme.colors.danger : theme.colors.textTertiary)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func runSearch(_ value: String) {
        searchTask?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onClearSearchResults()
            return
        }
        searchTask = Task {
            await onSearchChats(trimmed)
        }
    }

    private var visibleRows: [CodexCommandPaletteRow] {
        CodexCommandPaletteModel(
            query: query,
            commandRows: commandRows,
            chatResults: searchResults,
            isLoading: isSearchingChats,
            errorMessage: searchErrorMessage
        ).rows
    }

    private func reconcileNavigation() {
        var next = navigation
        next.reconcile(rows: visibleRows)
        navigation = next
    }

    private func focusSearchField() {
        // Deferring one run loop lets the overlay's hosting view become the key
        // view before asking SwiftUI to focus the field. This also handles the
        // palette reopening repeatedly from the same command-menu shortcut.
        DispatchQueue.main.async {
            isFocused = true
        }
    }

    private func navigate(_ direction: CodexCommandPaletteAction.NavigationDirection) {
        var next = navigation
        _ = next.move(direction, in: visibleRows)
        navigation = next
    }

    private func activateSelection() {
        guard let row = navigation.selectedRow(in: visibleRows) else {
            runSearch(query)
            return
        }
        select(row)
    }

    private func select(_ row: CodexCommandPaletteRow) {
        switch row.kind {
        case .command(let action):
            onClose()
            onSelectCommand(action)
        case .chat(let result):
            onClose()
            onSelectChat(result)
        }
    }

    private func isErrorStatus(_ status: CodexCommandPaletteStatus) -> Bool {
        if case .error = status { return true }
        return false
    }
}

/// A palette row. Split out so each row owns its own hover state — a command
/// palette whose rows do not respond to the pointer reads as a static list.
private struct PaletteRowButton: View {
    @Environment(\.codexAgentTheme) private var theme

    let row: CodexCommandPaletteRow
    let isSelected: Bool
    let select: (CodexCommandPaletteRow) -> Void
    let onHover: (Bool) -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            select(row)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: row.systemImage)
                    .font(theme.fonts.chipLabel)
                    .foregroundStyle(theme.colors.textTertiary)
                    .frame(width: 18, height: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title)
                        .font(theme.fonts.label)
                        .foregroundStyle(theme.colors.textPrimary)
                        .lineLimit(1)
                    Text(row.detail)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                if let shortcut = row.shortcutBadge {
                    Text(shortcut)
                        .font(theme.fonts.micro.weight(.semibold))
                        .foregroundStyle(theme.colors.textTertiary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(theme.colors.surfaceSunken.opacity(theme.effects.glassOpacity), in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            theme.colors.hover.opacity(isSelected ? theme.effects.selectionOpacity : (isHovered ? theme.effects.hoverOpacity : 0)),
            in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
        )
        .onHover {
            isHovered = $0
            onHover($0)
        }
        .animation(
            .easeOut(duration: theme.animations.snappyDuration),
            value: isHovered
        )
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Press Return to select")
    }
}

#if canImport(AppKit)
private struct CommandPaletteKeyMonitor: NSViewRepresentable {
    let onEscape: () -> Void
    let onNavigate: (CodexCommandPaletteAction.NavigationDirection) -> Void
    let onSelect: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEscape: onEscape, onNavigate: onNavigate, onSelect: onSelect)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onEscape = onEscape
        context.coordinator.onNavigate = onNavigate
        context.coordinator.onSelect = onSelect
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
        context.coordinator.onNavigate = onNavigate
        context.coordinator.onSelect = onSelect
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        var onEscape: () -> Void
        var onNavigate: (CodexCommandPaletteAction.NavigationDirection) -> Void
        var onSelect: () -> Void
        private var monitor: Any?

        init(
            onEscape: @escaping () -> Void,
            onNavigate: @escaping (CodexCommandPaletteAction.NavigationDirection) -> Void,
            onSelect: @escaping () -> Void
        ) {
            self.onEscape = onEscape
            self.onNavigate = onNavigate
            self.onSelect = onSelect
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                switch event.keyCode {
                case 53:
                    self.onEscape()
                    return nil
                case 125:
                    self.onNavigate(.down)
                    return nil
                case 126:
                    self.onNavigate(.up)
                    return nil
                case 36, 76:
                    self.onSelect()
                    return nil
                default:
                    return event
                }
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        deinit {
            uninstall()
        }
    }
}
#endif
