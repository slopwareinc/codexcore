import CodexCore
import SwiftUI

public struct CodexMarketplaceSummary: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var displayName: String
    public var path: String?
    public var localVersion: String?
    public var availableVersion: String?
    public var pluginCount: Int

    public init(
        name: String,
        displayName: String? = nil,
        path: String? = nil,
        localVersion: String? = nil,
        availableVersion: String? = nil,
        pluginCount: Int = 0
    ) {
        self.name = name
        self.displayName = displayName?.nilIfBlank ?? name
        self.path = path
        self.localVersion = localVersion
        self.availableVersion = availableVersion
        self.pluginCount = pluginCount
    }

    public var hasKnownUpdate: Bool {
        guard let localVersion, let availableVersion else { return false }
        return localVersion.compare(availableVersion, options: .numeric) == .orderedAscending
    }

    public static func summaries(from plugins: [CodexPluginSummary]) -> [CodexMarketplaceSummary] {
        Dictionary(grouping: plugins, by: \.marketplaceName).compactMap { name, plugins in
            guard let first = plugins.first else { return nil }
            let local = plugins.compactMap(\.localVersion).max { $0.compare($1, options: .numeric) == .orderedAscending }
            let available = plugins.compactMap(\.availableVersion).max { $0.compare($1, options: .numeric) == .orderedAscending }
            return .init(
                name: name,
                displayName: first.marketplaceDisplayName,
                path: first.marketplacePath,
                localVersion: local,
                availableVersion: available,
                pluginCount: plugins.count
            )
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public static func summaries(from response: CodexJSONValue) -> [CodexMarketplaceSummary] {
        guard case .dictionary(let object) = response,
              case .array(let values)? = object["marketplaces"] else { return [] }
        return values.compactMap { value in
            guard case .dictionary(let marketplace) = value,
                  let name = CodexJSONCoercion.flatString(from: marketplace["name"])?.nilIfBlank else {
                return nil
            }
            let interface: [String: CodexJSONValue]
            if case .dictionary(let value)? = marketplace["interface"] { interface = value }
            else { interface = [:] }
            let pluginCount: Int
            if case .array(let plugins)? = marketplace["plugins"] { pluginCount = plugins.count }
            else { pluginCount = 0 }
            return CodexMarketplaceSummary(
                name: name,
                displayName: CodexJSONCoercion.flatString(from: interface["displayName"])?.nilIfBlank ?? name,
                path: CodexJSONCoercion.flatString(from: marketplace["path"])?.nilIfBlank,
                localVersion: CodexJSONCoercion.flatString(from: marketplace["localVersion"])?.nilIfBlank,
                availableVersion: CodexJSONCoercion.flatString(from: marketplace["availableVersion"])?.nilIfBlank,
                pluginCount: pluginCount
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public static func marketplaces(from response: CodexJSONValue) -> [CodexMarketplaceSummary] {
        summaries(from: response)
    }
}

struct CodexMarketplaceManagementSheet: View {
    @Environment(\.codexAgentTheme) private var theme
    let marketplaces: [CodexMarketplaceSummary]
    let provider: (any CodexIntegrationControlPlaneProvider)?
    let onClose: () -> Void
    let onRefresh: () -> Void

    @State private var showsAdd = false
    @State private var pendingMarketplace: String?
    @State private var removal: CodexMarketplaceSummary?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Plugin marketplaces").font(theme.fonts.sheetTitle)
                Spacer()
                Button("Add marketplace") { showsAdd = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(provider == nil)
                Button(action: onClose) { Image(systemName: "xmark").frame(width: 28, height: 28) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close marketplace management")
            }
            if let message { Text(message).foregroundStyle(theme.colors.textSecondary) }
            if marketplaces.isEmpty {
                Text("No plugin marketplaces").foregroundStyle(theme.colors.textTertiary)
            } else {
                List(marketplaces) { marketplace in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(marketplace.displayName).font(theme.fonts.label)
                                if marketplace.hasKnownUpdate {
                                    Text("Update available").foregroundStyle(theme.colors.accentText)
                                }
                            }
                            Text(versionLabel(for: marketplace)).foregroundStyle(theme.colors.textSecondary)
                            if let path = marketplace.path?.nilIfBlank {
                                Text(path).font(theme.fonts.micro.monospaced()).foregroundStyle(theme.colors.textTertiary)
                            }
                        }
                        Spacer()
                        if pendingMarketplace == marketplace.name { ProgressView().controlSize(.small) }
                        Button(marketplace.hasKnownUpdate ? "Update" : "Check for updates") {
                            upgrade(marketplace)
                        }
                        .buttonStyle(.bordered)
                        Button("Remove", role: .destructive) { removal = marketplace }
                            .buttonStyle(.bordered)
                    }
                    .disabled(provider == nil || pendingMarketplace != nil)
                }
                .listStyle(.inset)
            }
        }
        .font(theme.fonts.caption)
        .padding(22)
        .frame(width: 680, height: 520)
        .sheet(isPresented: $showsAdd) {
            CodexMarketplaceAddSheet { showsAdd = false } onAdd: { source, refName, sparsePaths in
                add(source: source, refName: refName, sparsePaths: sparsePaths)
            }
            .codexAgentTheme(theme)
        }
        .confirmationDialog(
            "Remove plugin marketplace?",
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
            presenting: removal
        ) { marketplace in
            Button("Remove \(marketplace.displayName)", role: .destructive) { remove(marketplace) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func versionLabel(for marketplace: CodexMarketplaceSummary) -> String {
        switch (marketplace.localVersion, marketplace.availableVersion) {
        case (let local?, let available?): "Installed \(local) · Available \(available)"
        case (let local?, nil): "Installed \(local)"
        case (nil, let available?): "Available \(available)"
        case (nil, nil): "Version unavailable"
        }
    }

    private func add(source: String, refName: String?, sparsePaths: [String]?) {
        guard let provider else { return }
        showsAdd = false
        pendingMarketplace = source
        Task {
            do {
                _ = try await provider.perform(.marketplaceAdd(.init(refName: refName, source: source, sparsePaths: sparsePaths)))
                message = "Marketplace added."
                onRefresh()
            } catch { message = error.localizedDescription }
            pendingMarketplace = nil
        }
    }

    private func upgrade(_ marketplace: CodexMarketplaceSummary) {
        guard let provider else { return }
        pendingMarketplace = marketplace.name
        Task {
            do {
                let response = try await provider.perform(.marketplaceUpgrade(.init(marketplaceName: marketplace.name)))
                message = Self.upgradeMessage(response) ?? "Marketplace is up to date."
                onRefresh()
            } catch { message = error.localizedDescription }
            pendingMarketplace = nil
        }
    }

    private func remove(_ marketplace: CodexMarketplaceSummary) {
        guard let provider else { return }
        removal = nil
        pendingMarketplace = marketplace.name
        Task {
            do {
                _ = try await provider.perform(.marketplaceRemove(.init(marketplaceName: marketplace.name)))
                message = "Removed \(marketplace.displayName)."
                onRefresh()
            } catch { message = error.localizedDescription }
            pendingMarketplace = nil
        }
    }

    private static func upgradeMessage(_ response: CodexJSONValue) -> String? {
        guard case .dictionary(let object) = response,
              case .array(let errors)? = object["errors"], !errors.isEmpty else { return nil }
        return errors.compactMap { value in
            guard case .dictionary(let error) = value else { return nil }
            return CodexJSONCoercion.flatString(from: error["message"])
        }.joined(separator: "\n").nilIfBlank
    }
}

private struct CodexMarketplaceAddSheet: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var source = ""
    @State private var refName = ""
    @State private var sparsePaths = ""
    let onCancel: () -> Void
    let onAdd: (String, String?, [String]?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add plugin marketplace").font(theme.fonts.sheetTitle)
            TextField("Git URL or local path", text: $source)
            TextField("Git ref (optional)", text: $refName)
            TextField("Sparse paths (one per line)", text: $sparsePaths, axis: .vertical).lineLimit(3...7)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Add") {
                    let paths = sparsePaths.split(whereSeparator: \.isNewline).map(String.init).compactMap(\.nilIfBlank)
                    onAdd(source, refName.nilIfBlank, paths.isEmpty ? nil : paths)
                }
                .buttonStyle(.borderedProminent)
                .disabled(source.nilIfBlank == nil)
            }
        }
        .padding(22)
        .frame(width: 520, height: 300)
    }
}
