import SwiftUI
import CodexCore

struct CodexSkillRootsSheet: View {
    @Environment(\.codexAgentTheme) private var theme
    let provider: any CodexIntegrationControlPlaneProvider
    let onClose: () -> Void
    let onRefresh: () -> Void
    @State private var roots = ""
    @State private var error: String?
    @State private var isSaving = false
    @State private var confirmsReplacement = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Extra skill roots").font(theme.fonts.sheetTitle)
            Text("Enter one absolute directory per line. This replaces the extra roots for this Codex session; normal personal and project skill roots remain available.")
                .foregroundStyle(theme.colors.textSecondary)
            TextEditor(text: $roots).font(theme.fonts.code).frame(minHeight: 160)
            if let error { Text(error).foregroundStyle(theme.colors.danger) }
            HStack {
                Button("Cancel", action: onClose)
                Spacer()
                Button("Replace roots") { confirmsReplacement = true }.buttonStyle(.borderedProminent).disabled(isSaving)
            }
        }.padding(24).frame(width: 580).background(theme.colors.surface)
        .confirmationDialog("Replace extra skill roots?", isPresented: $confirmsReplacement) {
            Button("Replace roots") { save() }
        }
    }

    private func save() {
        let values = roots.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard values.allSatisfy({ $0.hasPrefix("/") }) else { error = "Every root must be an absolute directory path."; return }
        var seen = Set<String>()
        let paths = values.filter { seen.insert($0).inserted }.map { CodexSchemaAbsolutePathBuf(.string($0)) }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                _ = try await provider.perform(.skillsExtraRootsSet(.init(extraRoots: paths)))
                onRefresh()
                onClose()
            } catch { self.error = error.localizedDescription }
        }
    }
}
