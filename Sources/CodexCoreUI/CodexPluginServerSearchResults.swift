import SwiftUI

struct CodexPluginServerSearchResults: View {
    @Environment(\.codexAgentTheme) private var theme
    let query: String
    let workingDirectories: [String]
    let provider: any CodexIntegrationControlPlaneProvider
    let pendingIDs: Set<String>
    let onSelect: (CodexPluginSummary) -> Void
    let onAction: (CodexPluginRouteAction) -> Void
    @State private var results: [CodexPluginSummary] = []
    @State private var nextCursor: String?
    @State private var seenCursors: Set<String> = []
    @State private var generation = UUID()
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search results").font(theme.fonts.chat.weight(.semibold))
            if isLoading { ProgressView("Searching marketplaces") }
            if let error { Text(error).foregroundStyle(theme.colors.danger) }
            LazyVStack(spacing: CodexPluginLayoutMetrics.rowSpacing) {
                ForEach(results) { plugin in
                    OfficialPluginRow(plugin: plugin, showsToggle: false, isPending: pendingIDs.contains(plugin.protocolID),
                                      onOpen: { onSelect(plugin) }, onAction: onAction)
                }
            }
            if !isLoading && results.isEmpty && error == nil {
                Text("No plugins found. Try a different search.").foregroundStyle(theme.colors.textSecondary)
            }
            if nextCursor != nil {
                Button("Load more") { Task { await load(reset: false) } }.disabled(isLoading)
            }
        }
        .task(id: query) {
            generation = UUID()
            isLoading = false
            results = []
            nextCursor = nil
            seenCursors = []
            do { try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation() }
            catch { return }
            await load(reset: true)
        }
    }

    private func load(reset: Bool) async {
        guard !isLoading else { return }
        let ticket = generation
        isLoading = true
        defer { if generation == ticket { isLoading = false } }
        do {
            let page = try await CodexIntegrationFeatureWorkflows.searchPlugins(
                query: query, cursor: reset ? nil : nextCursor, workingDirectories: workingDirectories, provider: provider
            )
            guard generation == ticket, !Task.isCancelled else { return }
            if let cursor = page.nextCursor, !seenCursors.insert(cursor).inserted {
                nextCursor = nil
                throw CodexIntegrationControlPlaneError("The marketplace returned a repeated cursor.")
            }
            var ids = Set(results.map(\.id))
            results += page.plugins.filter { ids.insert($0.id).inserted }
            nextCursor = page.nextCursor
            error = nil
        } catch is CancellationError { } catch {
            guard generation == ticket else { return }
            self.error = error.localizedDescription
        }
    }
}
