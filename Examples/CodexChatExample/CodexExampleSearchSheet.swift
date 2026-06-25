import SwiftUI
import CodexCore
import CodexCoreUI

struct CommandPaletteOverlay: View {
    @Environment(\.codexAgentTheme) private var theme

    @Bindable var model: CodexChatModel
    let onClose: () -> Void
    let onSelectChat: (CodexThreadSearchResult) -> Void
    let onSelectCommand: (CodexCommandPaletteAction) -> Void

    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            palette
                .padding(.top, 72)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear { isFocused = true }
        .onDisappear {
            searchTask?.cancel()
            model.clearSearchResults()
        }
        .onExitCommand(perform: onClose)
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
        .background(theme.colors.surface.opacity(0.98), in: RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.32), radius: 28, x: 0, y: 18)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Command menu")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Text("Search commands and past chats.")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.colors.textTertiary)
            TextField("Search chats or run a command", text: $query)
                .textFieldStyle(.plain)
                .font(theme.fonts.chat)
                .foregroundStyle(theme.colors.textPrimary)
                .focused($isFocused)
                .onSubmit { runSearch(query) }
            if model.isSearchingChats {
                ProgressView()
                    .controlSize(.small)
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
                model.clearSearchResults()
                return
            }
            searchTask = Task {
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
                await model.searchChats(query: trimmed)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let paletteModel = CodexCommandPaletteModel(
            query: query,
            commandRows: CodexCommandPaletteModel.defaultCommandRows,
            chatResults: model.searchResults,
            isLoading: model.isSearchingChats,
            errorMessage: model.searchErrorMessage
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
        Button {
            select(row)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: row.systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.colors.textTertiary)
                    .frame(width: 18, height: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title)
                        .font(.system(size: 13, weight: .semibold))
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
        .background(theme.colors.surfaceElevated.opacity(0.34), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .accessibilityLabel(row.accessibilityLabel)
    }

    private func emptyCategoryRow(_ title: String) -> some View {
        Text(title == "Chats" ? "Search past chats by title, project, or transcript." : "No quick actions")
            .font(theme.fonts.caption)
            .foregroundStyle(theme.colors.textTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.colors.surfaceElevated.opacity(0.18), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
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
            await model.searchChats(query: value)
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
