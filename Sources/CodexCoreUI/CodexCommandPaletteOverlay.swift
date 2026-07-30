import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

public struct CodexCommandPaletteOverlay: View {
    @Environment(\.codexAgentTheme) private var theme

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
    @FocusState private var isFocused: Bool

    public init(
        searchResults: [CodexThreadSearchResult],
        isSearchingChats: Bool,
        searchErrorMessage: String?,
        onClose: @escaping () -> Void,
        onSearchChats: @escaping (String) async -> Void,
        onClearSearchResults: @escaping () -> Void,
        onSelectChat: @escaping (CodexThreadSearchResult) -> Void,
        onSelectCommand: @escaping (CodexCommandPaletteAction) -> Void
    ) {
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
            .onAppear { isFocused = true }
            .onDisappear {
                searchTask?.cancel()
                onClearSearchResults()
            }
            .onExitCommand(perform: onClose)
            #if canImport(AppKit)
            .background(CommandPaletteEscapeMonitor(onEscape: onClose))
            #endif
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Command menu")
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
                .onSubmit { runSearch(query) }
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
            commandRows: CodexCommandPaletteModel.defaultCommandRows,
            chatResults: searchResults,
            isLoading: isSearchingChats,
            errorMessage: searchErrorMessage
        )

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
    }

    private func sectionView(_ section: CodexCommandPaletteSection) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(section.title)
                .font(theme.fonts.caption.weight(.semibold))
                .foregroundStyle(theme.colors.textTertiary)
                .padding(.horizontal, 4)

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
        PaletteRowButton(row: row, select: select)
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
        searchTask = Task {
            await onSearchChats(value)
        }
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
    let select: (CodexCommandPaletteRow) -> Void

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
            theme.colors.hover.opacity(isHovered ? theme.effects.hoverOpacity : 0),
            in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
        )
        .onHover { isHovered = $0 }
        .animation(
            .easeOut(duration: theme.animations.snappyDuration),
            value: isHovered
        )
        .accessibilityLabel(row.accessibilityLabel)
    }
}

#if canImport(AppKit)
private struct CommandPaletteEscapeMonitor: NSViewRepresentable {
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEscape: onEscape)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onEscape = onEscape
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        var onEscape: () -> Void
        private var monitor: Any?

        init(onEscape: @escaping () -> Void) {
            self.onEscape = onEscape
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event }
                self?.onEscape()
                return nil
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
