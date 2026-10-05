import SwiftUI
import CodexCore

enum CodexPluginSharingInput {
    /// One explicit target per line: user|group|workspace ID reader|editor.
    static func targets(_ text: String) throws -> [CodexSchemaPluginShareTarget] {
        try text.split(whereSeparator: \.isNewline).map { line in
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count == 3, ["user", "group", "workspace"].contains(parts[0]),
                  let kind = CodexSchemaPluginSharePrincipalType(rawValue: parts[0]),
                  let role = CodexSchemaPluginShareTargetRole(rawValue: parts[2]) else {
                throw CodexIntegrationControlPlaneError("Each target must use: user|group|workspace ID reader|editor.")
            }
            return .init(principalID: parts[1], principalType: kind, role: role)
        }
    }

    static func text(_ principals: [CodexSchemaPluginSharePrincipal]) -> String {
        principals.compactMap { principal in
            guard principal.role == .reader || principal.role == .editor else { return nil }
            return "\(principal.principalType.rawValue) \(principal.principalID) \(principal.role.rawValue)"
        }.joined(separator: "\n")
    }
}

struct CodexPluginSharingSheet: View {
    @Environment(\.codexAgentTheme) private var theme
    let provider: any CodexIntegrationControlPlaneProvider
    let onClose: () -> Void
    let onRefresh: () -> Void
    @State private var items: [CodexSchemaPluginShareListItem] = []
    @State private var localPath = ""
    @State private var remoteID = ""
    @State private var discoverability = CodexSchemaPluginShareUpdateDiscoverability.pRIVATE
    @State private var targets = ""
    @State private var shareURL: String?
    @State private var error: String?
    @State private var isLoading = false
    @State private var isMutating = false
    @State private var pendingRequest: CodexIntegrationControlPlaneRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Shared plugins").font(theme.fonts.sheetTitle)
                Spacer()
                Button("Refresh") { Task { await load() } }.disabled(isLoading || isMutating)
                Button("Close", systemImage: "xmark", action: onClose).labelStyle(.iconOnly)
            }
            if isLoading { ProgressView("Loading shared plugins") }
            if let error { Text(error).foregroundStyle(theme.colors.danger).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Button {
                            remoteID = item.plugin.remotePluginID ?? item.plugin.shareContext?.remotePluginID ?? ""
                            localPath = item.localPluginPath?.rawValue.stringValue ?? ""
                            targets = CodexPluginSharingInput.text(item.plugin.shareContext?.sharePrincipals ?? [])
                            if let raw = item.plugin.shareContext?.discoverability?.rawValue,
                               let mode = CodexSchemaPluginShareUpdateDiscoverability(rawValue: raw) { discoverability = mode }
                            shareURL = item.plugin.shareContext?.shareUrl
                        } label: {
                            HStack {
                                Text(item.plugin.interface?.displayName ?? item.plugin.name)
                                Spacer()
                                Text(item.plugin.shareContext?.discoverability?.rawValue ?? "Shared")
                                    .foregroundStyle(theme.colors.textSecondary)
                            }.padding(10).background(theme.colors.surfaceSunken, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                    if !isLoading && items.isEmpty { Text("No shared plugins yet.").foregroundStyle(theme.colors.textSecondary) }
                }
            }.frame(maxHeight: 180)
            TextField("Local plugin directory (absolute path)", text: $localPath).textFieldStyle(.roundedBorder)
            TextField("Remote plugin ID", text: $remoteID).textFieldStyle(.roundedBorder)
            Picker("Visibility", selection: $discoverability) {
                ForEach(CodexSchemaPluginShareUpdateDiscoverability.allCases, id: \.rawValue) { mode in
                    Text(mode.rawValue.capitalized).tag(mode)
                }
            }
            Text("Access targets · one per line: user|group|workspace ID reader|editor")
                .foregroundStyle(theme.colors.textSecondary)
            TextEditor(text: $targets).font(theme.fonts.code).frame(height: 80)
                .border(theme.colors.border)
            if let shareURL, let url = URL(string: shareURL), url.scheme == "https" {
                Link("Open shared plugin", destination: url)
            }
            HStack {
                Button("Publish or update") { proposeSave() }.disabled(!localPath.hasPrefix("/"))
                Button("Update access") { proposeTargets() }.disabled(remoteID.isEmpty)
                Button("Check out locally") {
                    pendingRequest = .pluginShareCheckout(.init(remotePluginID: remoteID))
                }.disabled(remoteID.isEmpty)
                Spacer()
                Button("Delete share", role: .destructive) {
                    pendingRequest = .pluginShareDelete(.init(remotePluginID: remoteID))
                }.disabled(remoteID.isEmpty)
            }.disabled(isMutating)
        }
        .font(theme.fonts.caption).padding(24).frame(width: 760, height: 650).background(theme.colors.surface)
        .task { await load() }
        .confirmationDialog("Confirm plugin sharing change", isPresented: Binding(
            get: { pendingRequest != nil }, set: { if !$0 { pendingRequest = nil } }
        )) {
            Button(pendingRequest?.operationID == "plugin/share/delete" ? "Delete share" : "Continue",
                   role: pendingRequest?.operationID == "plugin/share/delete" ? .destructive : nil) { perform() }
        } message: {
            Text(pendingRequest?.operationID == "plugin/share/checkout"
                ? "This downloads the shared plugin into the local Codex marketplace."
                : "This changes a shared plugin or the people who can access it. Verify the visibility and targets before continuing.")
        }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await provider.perform(.pluginShareList(.init())).decode(CodexSchemaPluginShareListResponse.self)
            try Task.checkCancellation()
            items = response.data
            error = nil
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }

    private func proposeSave() {
        do {
            pendingRequest = .pluginShareSave(.init(
                discoverability: CodexSchemaPluginShareDiscoverability(rawValue: discoverability.rawValue),
                pluginPath: .init(.string(localPath.trimmingCharacters(in: .whitespacesAndNewlines))),
                remotePluginID: remoteID.nilIfBlank, shareTargets: try CodexPluginSharingInput.targets(targets)
            ))
        } catch { self.error = error.localizedDescription }
    }

    private func proposeTargets() {
        do {
            pendingRequest = .pluginShareUpdateTargets(.init(
                discoverability: discoverability, remotePluginID: remoteID,
                shareTargets: try CodexPluginSharingInput.targets(targets)
            ))
        } catch { self.error = error.localizedDescription }
    }

    private func perform() {
        guard let request = pendingRequest else { return }
        pendingRequest = nil
        isMutating = true
        Task {
            defer { isMutating = false }
            do {
                let response = try await provider.perform(request)
                if case .pluginShareSave = request {
                    let saved = try response.decode(CodexSchemaPluginShareSaveResponse.self)
                    remoteID = saved.remotePluginID
                    shareURL = saved.shareUrl
                }
                onRefresh()
                await load()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private extension CodexJSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}
