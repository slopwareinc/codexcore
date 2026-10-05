import SwiftUI
import CodexCoreUI

/// Host-owned feature pages keep runtime ownership out of the reusable UI module.
struct CodexAppRuntimeFeaturesView: View {
    @Bindable var model: CodexCoreAppModel
    @State private var page: Page = .account
    @State private var showingChat = false

    private enum Page: String, CaseIterable, Identifiable {
        case account = "Account", voice = "Voice", chat = "Chat", projects = "Projects"
        case environments = "Environments", feedback = "Feedback"
        case remote = "Remote control"
        case processes = "Processes"
        case files = "Files", imports = "Imports", experiments = "Experiments"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Runtime features").font(.title2.bold())
            Picker("Feature", selection: $page) {
                ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.menu)
            if !model.isConnected { Text("Connect to Codex to use runtime features.").foregroundStyle(.secondary) }
            content
                .frame(minHeight: 420)
        }
        .sheet(isPresented: $showingChat) {
            CodexThreadFeaturesSheet(controller: model.threadFeatures, modelOptions: model.modelOptions,
                                     projects: model.threadListSession.recentProjects, plugins: model.plugins)
                .codexAgentTheme(model.theme)
        }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .processes: CodexAppProcessFeaturesView(features: model.processFeatures, workspacePath: model.workspacePath, threadID: model.currentThreadID)
        case .environments: CodexAppEnvironmentFeaturesView(features: model.environmentFeatures)
        case .feedback: CodexAppFeedbackFeaturesView(features: model.feedbackFeatures, threadID: model.currentThreadID)
        case .remote: CodexAppRemoteControlFeaturesView(features: model.remoteControlFeatures)
        case .account:
            CodexAppAccountFeaturesView(features: model.accountFeatures, onProviderChanged: { await model.disconnect(); await model.connect() })
        case .voice:
            CodexVoiceSettingsView(session: model.voiceSession, onRefreshVoices: {
                guard let codex = model.codex else { return }
                await model.voiceSession.refreshVoices(codex: codex)
            })
        case .chat:
            VStack(alignment: .leading, spacing: 12) {
                Text(model.currentThreadID.map { "Selected chat: \($0)" } ?? "Select a chat first.").textSelection(.enabled)
                Text("Manage durable resources, memory, history, goals, settings, and queued messages.").foregroundStyle(.secondary)
                Button("Open chat features") { showingChat = true }.disabled(model.currentThreadID == nil)
                if let error = model.liveTurnSettings.errorMessage { Text(error).foregroundStyle(.red) }
                if let message = model.liveTurnSettings.message { Text(message).foregroundStyle(.secondary) }
                Spacer()
            }
        case .projects: CodexAppProjectFeaturesView(features: model.projectFeatures)
        case .files: CodexAppFileFeaturesView(features: model.fileFeatures, roots: model.workspaceRoots)
        case .imports: CodexAppImportFeaturesView(features: model.importFeatures, folders: model.workspaceRoots)
        case .experiments: CodexAppExperimentalFeaturesView(features: model.experimentalFeatures, threadID: model.currentThreadID)
        }
    }
}
