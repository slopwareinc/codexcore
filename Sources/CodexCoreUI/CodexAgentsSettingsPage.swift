import SwiftUI

public struct CodexAgentsSettingsPage: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var snapshot: CodexAgentsDocumentSnapshot?
    @State private var globalContent = ""
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var isSaving = false

    let store: CodexAgentsDocumentStore?
    let codexHome: String?
    let workingDirectory: String?

    public init(
        store: CodexAgentsDocumentStore?,
        codexHome: String?,
        workingDirectory: String?
    ) {
        self.store = store
        self.codexHome = codexHome
        self.workingDirectory = workingDirectory
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            CodexSettingsPageTitle("Agent instructions")
            Text("These trusted files can authorize agent actions. Review the precedence order before starting work.")
                .font(theme.fonts.body)
                .foregroundStyle(theme.colors.textSecondary)

            if let snapshot {
                layerInspector(snapshot)
                globalEditor(snapshot)
            } else if isLoading {
                ProgressView("Resolving AGENTS.md files…")
            } else {
                CodexSettingsReadOnlyRow(
                    title: "Instructions unavailable",
                    detail: errorMessage ?? "Connect a Codex filesystem and select a workspace to inspect trusted instructions.",
                    value: nil,
                    systemImage: "exclamationmark.shield"
                )
                .agentsSettingsPanel(theme: theme)
            }
        }
        .task { await load() }
    }

    private func layerInspector(_ snapshot: CodexAgentsDocumentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Resolved precedence")
                .font(theme.fonts.panelTitle)
                .foregroundStyle(theme.colors.textPrimary)
            Text("Lowest precedence first · project root: \(snapshot.projectRoot)")
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textTertiary)
            VStack(spacing: 0) {
                if snapshot.layers.isEmpty {
                    CodexSettingsReadOnlyRow(
                        title: "No instruction files found",
                        detail: "Neither the global nor project layers contain an instruction document.",
                        value: nil,
                        systemImage: "doc.badge.ellipsis"
                    )
                } else {
                    ForEach(Array(snapshot.layers.enumerated()), id: \.element.id) { index, layer in
                        CodexSettingsReadOnlyRow(
                            title: layer.path,
                            detail: layer.isTruncated
                                ? "\(layer.size.formatted()) bytes · truncated by project byte cap"
                                : "\(layer.size.formatted()) bytes",
                            value: "\(index + 1)",
                            systemImage: layer.scope == .global ? "person.crop.circle" : "folder"
                        )
                    }
                }
            }
            .agentsSettingsPanel(theme: theme)
        }
    }

    private func globalEditor(_ snapshot: CodexAgentsDocumentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Global instructions")
                        .font(theme.fonts.panelTitle)
                        .foregroundStyle(theme.colors.textPrimary)
                    Text(snapshot.globalPath)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button(isSaving ? "Saving…" : "Save") {
                    Task { await save() }
                }
                .disabled(isSaving)
            }
            TextEditor(text: $globalContent)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 220)
                .background(theme.colors.surfaceElevated.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                        .stroke(theme.colors.border, lineWidth: 1)
                )
            if let errorMessage {
                Text(errorMessage)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.danger)
            }
        }
    }

    @MainActor
    private func load() async {
        guard let store, let codexHome, let workingDirectory else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let resolved = try await store.resolve(codexHome: codexHome, workingDirectory: workingDirectory)
            snapshot = resolved
            globalContent = resolved.globalContent
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func save() async {
        guard let store, let codexHome else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await store.saveGlobal(content: globalContent, codexHome: codexHome)
            errorMessage = nil
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension View {
    func agentsSettingsPanel(theme: CodexAgentTheme) -> some View {
        self
            .padding(16)
            .background(
                theme.colors.surfaceElevated.opacity(theme.effects.glassOpacity),
                in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                    .stroke(theme.colors.border, lineWidth: 1)
            )
    }
}
