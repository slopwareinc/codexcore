import SwiftUI
import CodexCore
import CodexCoreUI

struct CodexAppExperimentalFeaturesView: View {
    @Bindable var features: CodexAppExperimentalFeatures
    let threadID: String?
    @Environment(\.codexAgentTheme) private var theme
    @State private var pendingFeature: CodexSchemaExperimentalFeature?
    @State private var confirmCompression = false

    var body: some View {
        Form {
            Section("Experimental features") {
                HStack {
                    Text("Availability follows your Codex runtime and managed configuration.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { Task { await features.refresh(threadID: threadID) } }
                }
                if let error = features.error { Text(error).foregroundStyle(theme.colors.danger) }
                ForEach(features.features, id: \.name) { feature in
                    Toggle(isOn: Binding(get: { feature.enabled }, set: { _ in pendingFeature = feature })) {
                        VStack(alignment: .leading) {
                            Text(feature.displayName ?? feature.name)
                            if let detail = feature.description { Text(detail).font(.caption).foregroundStyle(.secondary) }
                            Text(feature.stage.rawValue).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if features.features.isEmpty && !features.isLoading { Text("No experimental features were returned.").foregroundStyle(.secondary) }
            }
            Section("Stored chat maintenance") {
                Text("Compress eligible local rollouts in the background. Active chats remain available.")
                    .foregroundStyle(.secondary)
                Button("Schedule rollout compression") { confirmCompression = true }
                if let result = features.compressionResult { Text(result).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped).disabled(features.isLoading)
        .overlay(alignment: .topTrailing) { if features.isLoading { ProgressView().padding() } }
        .task { await features.refresh(threadID: threadID) }
        .confirmationDialog("Change experimental feature?", isPresented: Binding(get: { pendingFeature != nil }, set: { if !$0 { pendingFeature = nil } })) {
            if let feature = pendingFeature {
                Button(feature.enabled ? "Disable" : "Enable") {
                    pendingFeature = nil
                    Task { await features.setEnabled(!feature.enabled, name: feature.name, threadID: threadID) }
                }
            }
            Button("Cancel", role: .cancel) { pendingFeature = nil }
        }
        .confirmationDialog("Schedule local rollout compression?", isPresented: $confirmCompression) {
            Button("Schedule compression") { Task { await features.compressRollouts() } }
            Button("Cancel", role: .cancel) {}
        }
    }
}
