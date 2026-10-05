import SwiftUI
import CodexCore

struct CodexSkillDetailSheet: View {
    @Environment(\.codexAgentTheme) private var theme
    let skill: CodexSkillSummary
    let icon: CodexPluginIconReference
    let isPending: Bool
    let provider: (any CodexIntegrationControlPlaneProvider)?
    let onClose: () -> Void
    let onRefresh: () -> Void
    let onAction: (CodexPluginRouteAction) -> Void

    @State private var document: CodexSkillDocument?
    @State private var isLoading = false
    @State private var isRemoving = false
    @State private var error: String?
    @State private var confirmsRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                CodexPluginIconView(reference: icon, size: 46, fallbackSystemName: "hammer")
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.displayName).font(theme.fonts.sheetTitle)
                    Text(skill.scopeLabel).foregroundStyle(theme.colors.textSecondary)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(get: { skill.enabled }, set: {
                    onAction(.setSkillEnabled(.init(skill: skill), enabled: $0))
                })).toggleStyle(.switch).disabled(isPending || isRemoving)
                Button("Close", systemImage: "xmark", action: onClose).labelStyle(.iconOnly)
            }
            if isLoading { ProgressView("Loading skill instructions") }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(theme.colors.danger) }
            let parsedAllowed = document?.allowedTools ?? []
            let allowed = parsedAllowed.isEmpty ? skill.allowedTools : parsedAllowed
            if !allowed.isEmpty {
                Text("Allowed tools: \(allowed.joined(separator: ", "))")
                    .font(theme.fonts.caption).textSelection(.enabled)
            }
            if document?.disablesModelInvocation == true || skill.disablesModelInvocation {
                Label("Explicit invocation required", systemImage: "person.crop.circle.badge.checkmark")
                    .font(theme.fonts.caption).foregroundStyle(theme.colors.warning)
            }
            if !skill.dependencies.isEmpty {
                Text("Dependencies: \(skill.dependencies.joined(separator: ", "))")
                    .font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary)
            }
            ScrollView {
                Text(document?.body ?? skill.description.nilIfBlank ?? skill.detail)
                    .font(theme.fonts.chat).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16).background(theme.colors.surfaceSunken, in: RoundedRectangle(cornerRadius: 12))
            }
            Text(skill.path).font(theme.fonts.micro.monospaced()).foregroundStyle(theme.colors.textTertiary).textSelection(.enabled)
            HStack {
                if CodexIntegrationFeatureWorkflows.canRemove(skill) {
                    Button("Remove personal skill", role: .destructive) { confirmsRemoval = true }
                        .disabled(provider == nil || isRemoving || isPending)
                }
                Spacer()
                if let prompt = skill.defaultPrompt {
                    Button("Try in chat") { onAction(.tryInChat(prompt: prompt)) }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24).frame(minWidth: 560, idealWidth: 760, minHeight: 420, idealHeight: 620)
        .background(theme.colors.surface)
        .task(id: skill.id) { await load() }
        .confirmationDialog("Remove \(skill.displayName)?", isPresented: $confirmsRemoval) {
            Button("Remove personal skill", role: .destructive) { remove() }
        } message: {
            Text("This deletes the personal skill directory and its supporting files. It cannot be undone.")
        }
    }

    private func load() async {
        guard let provider else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let value = try await CodexIntegrationFeatureWorkflows.skillDocument(skill, provider: provider)
            try Task.checkCancellation()
            document = value
            error = nil
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }

    private func remove() {
        guard let provider else { return }
        isRemoving = true
        Task {
            defer { isRemoving = false }
            do {
                try await CodexIntegrationFeatureWorkflows.removeSkill(skill, provider: provider)
                onRefresh()
                onClose()
            } catch { self.error = error.localizedDescription }
        }
    }
}
