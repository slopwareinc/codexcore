import SwiftUI
import CodexCoreUI

struct CodexAppImportFeaturesView: View {
    @Bindable var features: CodexAppImportFeatures
    let folders: [String]
    @Environment(\.codexAgentTheme) private var theme
    @State private var source = ""
    @State private var includeHome = true
    @State private var selected: Set<Int> = []
    @State private var confirmImport = false
    @State private var receiptProvider = ""

    var body: some View {
        Form {
            Section("Bring your setup to Codex") {
                TextField("Source (optional)", text: $source)
                Toggle("Include settings and sessions from your home folder", isOn: $includeHome)
                HStack {
                    Button("Find importable items") {
                        Task { await features.detect(source: source, folders: folders, includeHome: includeHome); selected = [] }
                    }
                    Button("Refresh history") { Task { await features.readHistory() } }
                }
                if let error = features.error { Text(error).foregroundStyle(theme.colors.danger) }
                if features.isLoading || features.isImporting { ProgressView(features.isImporting ? "Importing…" : "Finding items…") }
            }
            if !features.items.isEmpty {
                Section("Choose items") {
                    ForEach(Array(features.items.enumerated()), id: \.offset) { index, item in
                        Toggle(isOn: Binding(get: { selected.contains(index) }, set: {
                            if $0 { selected.insert(index) } else { selected.remove(index) }
                        })) {
                            VStack(alignment: .leading) {
                                Text(item.description)
                                Text([item.itemType.rawValue, item.cwd].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Import selected items") { confirmImport = true }
                        .buttonStyle(.borderedProminent).disabled(selected.isEmpty || features.isImporting)
                }
            }
            if let completion = features.completion {
                Section("Latest import") {
                    let successes = completion.itemTypeResults.reduce(0) { $0 + $1.successes.count }
                    let failures = completion.itemTypeResults.reduce(0) { $0 + $1.failures.count }
                    Text("\(successes) imported · \(failures) failed")
                    TextField("Provider for a separate import receipt", text: $receiptProvider)
                    Button("Record receipt") { Task { await features.recordReceipt(providerID: receiptProvider) } }
                        .disabled(receiptProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Section("Import history") {
                if features.histories.isEmpty { Text("No completed imports.").foregroundStyle(.secondary) }
                ForEach(features.histories, id: \.importID) { history in
                    VStack(alignment: .leading) {
                        Text("\(history.successes.count) imported · \(history.failures.count) failed")
                        Text(Date(timeIntervalSince1970: Double(history.completedAtMs) / 1_000), style: .date)
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(history.failures.enumerated()), id: \.offset) { _, failure in
                            Text(failure.message).font(.caption).foregroundStyle(theme.colors.danger)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await features.readHistory() }
        .confirmationDialog("Import the selected configuration and chats?", isPresented: $confirmImport) {
            Button("Import") { Task { await features.startImport(indices: selected, source: source) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Codex will apply the selected source settings and migration items to this home.") }
    }
}
