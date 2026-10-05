import SwiftUI
import CodexCore
import CodexCoreUI

struct CodexAppFeedbackFeaturesView: View {
    @Environment(\.codexAgentTheme) private var theme
    @Bindable var features: CodexAppFeedbackFeatures
    let threadID: String?
    @State private var category: CodexAppFeedbackCategory = .bug
    @State private var reason = ""
    @State private var includesChat = true
    @State private var includesLogs = false
    @State private var extraFiles = ""
    @State private var tags = ""
    @State private var pendingUpload: CodexSchemaFeedbackUploadParams?
    @State private var confirmsUpload = false
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.lg) {
            Text("Send feedback").font(theme.fonts.panelTitle)
            Picker("Category", selection: $category) {
                ForEach(CodexAppFeedbackCategory.allCases) { Text($0.title).tag($0) }
            }
            Text("Describe what happened").font(theme.fonts.label)
            TextEditor(text: $reason).font(theme.fonts.body).frame(minHeight: 90, maxHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: theme.radii.small).stroke(theme.colors.border))
            if let threadID {
                Toggle("Associate with the selected chat", isOn: $includesChat)
                Text(threadID).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary).textSelection(.enabled)
            }
            Toggle("Upload logs and diagnostics", isOn: $includesLogs)
            Text(includesLogs
                ? "Uploads can include runtime logs, diagnostics, tool caches, and selected chat and agent transcripts."
                : "Your category, note, and optional chat reference will be sent without log attachments.")
                .font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary)
            DisclosureGroup("Additional files and tags") {
                VStack(alignment: .leading, spacing: theme.spacing.sm) {
                    Text("Additional log files: one absolute path on the app-server host per line.").font(theme.fonts.caption)
                    TextEditor(text: $extraFiles).frame(height: 60).disabled(!includesLogs)
                    Text("Tags: one key=value per line. Values may contain =.").font(theme.fonts.caption)
                    TextEditor(text: $tags).frame(height: 60)
                }.font(theme.fonts.body)
            }
            Button(features.isUploading ? "Uploading…" : "Review feedback…") { review() }
                .disabled(features.isUploading)
            if let error = validationError ?? features.errorMessage { CodexErrorBanner(message: error) }
            if let receipt = features.receipt {
                Text("Feedback received. Reference: \(receipt.threadID)").font(theme.fonts.label).textSelection(.enabled)
                if let hash = receipt.promptHash { Text("Prompt reference: \(hash)").font(theme.fonts.caption).textSelection(.enabled) }
            }
        }
        .foregroundStyle(theme.colors.textPrimary)
        .confirmationDialog("Send this feedback to OpenAI?", isPresented: $confirmsUpload) {
            Button("Send feedback") {
                guard let params = pendingUpload else { return }
                pendingUpload = nil
                Task { await features.upload(params) }
            }
            Button("Cancel", role: .cancel) { pendingUpload = nil }
        } message: {
            if let pendingUpload {
                Text("Category: \(pendingUpload.classification). \(pendingUpload.includeLogs == true ? "Includes logs and diagnostics." : "No log attachments.") \(pendingUpload.threadID == nil ? "No chat reference." : "Includes the selected chat reference.") Additional files: \(pendingUpload.extraLogFiles?.count ?? 0). Tags: \(pendingUpload.tags?.count ?? 0).")
            }
        }
        .onDisappear { pendingUpload = nil; confirmsUpload = false }
    }

    private func review() {
        do {
            pendingUpload = try CodexAppFeedbackFeatures.parameters(category: category, reason: reason,
                threadID: includesChat ? threadID : nil, includeLogs: includesLogs, extraFiles: extraFiles, tags: tags)
            validationError = nil
            confirmsUpload = true
        } catch { validationError = (error as? CodexAppFeatureError)?.localizedDescription ?? "Check the feedback settings." }
    }
}
