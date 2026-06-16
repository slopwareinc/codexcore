import SwiftUI
import CodexCore
import CodexCoreUI

struct SearchChatsSheet: View {
    @Environment(\.codexAgentTheme) private var theme

    @Bindable var model: CodexChatModel
    let onClose: () -> Void
    let onSelect: (CodexThreadSearchResult) -> Void
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Search chats")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.colors.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.colors.textTertiary)
                TextField("Search previous chats", text: $query)
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
            .frame(height: 38)
            .background(theme.colors.surfaceElevated.opacity(0.82), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                    .stroke(theme.colors.border, lineWidth: 1)
            )

            Group {
                if let error = model.searchErrorMessage {
                    Text(error)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                } else if model.searchResults.isEmpty, !model.isSearchingChats {
                    Text("No matching chats")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.searchResults) { result in
                        SearchResultRow(result: result) {
                            onSelect(result)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 300)
        }
        .padding(18)
        .frame(width: 520, height: 430)
        .background(theme.colors.surface)
        .onAppear { isFocused = true }
        .onDisappear {
            searchTask?.cancel()
            model.clearSearchResults()
        }
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

    private func runSearch(_ value: String) {
        searchTask?.cancel()
        searchTask = Task {
            await model.searchChats(query: value)
        }
    }
}

private struct SearchResultRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let result: CodexThreadSearchResult
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.colors.textTertiary)
                    .frame(width: 18, height: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.thread.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.colors.textPrimary)
                        .lineLimit(1)
                    Text(result.snippet.isEmpty ? result.thread.detail : result.snippet)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(2)
                    Text(projectLabel)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(theme.colors.surfaceElevated.opacity(0.34), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
    }

    private var projectLabel: String {
        guard let path = result.thread.workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return result.thread.id
        }
        return path
    }
}

