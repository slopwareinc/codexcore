import SwiftUI
import CodexCoreUI

/// One binding/action boundary for routed settings and the standalone window.
struct CodexAppSettingsContent: View {
    @Bindable var model: CodexCoreAppModel
    var onBackToApp: (() -> Void)? = nil

    var body: some View {
        CodexSettingsAboutRouteView(
            metadata: CodexAboutMetadata(
                bundle: .main,
                serverName: model.serverName,
                fallbackAppName: "CodexCore",
                fallbackCopyright: "© Slopware"
            ),
            accountSummary: model.accountMenuSummary,
            appearanceSettings: $model.appearanceSettings,
            approvalSelection: $model.approvalSelection,
            approvalOptions: model.approvalOptions,
            agentsDocumentStore: model.agentsDocumentStore,
            codexHomePath: model.codexHome.path,
            workingDirectory: model.workspacePath,
            modelSelection: $model.modelSelection,
            modelOptions: model.modelOptions,
            reasoningSelection: $model.reasoningSelection,
            isBottomPanelVisible: .constant(false),
            newThreadHistoryMode: $model.newThreadHistoryMode,
            mcpServers: model.mcpServers,
            isLoadingMCPServers: model.isLoadingMCPServers,
            serverDiagnostics: model.serverDiagnostics,
            isLoadingServerDiagnostics: model.isLoadingServerDiagnostics,
            serverDiagnosticsError: model.serverDiagnosticsError,
            onRefreshServerDiagnostics: {
                Task { await model.refreshServerDiagnostics() }
            },
            threadSections: model.threadSections,
            isLoadingThreadSections: model.isLoadingThreadSections,
            threadSectionsError: model.threadSectionsError,
            onRefreshThreadSections: {
                Task { await model.refreshThreadSections() }
            },
            onCreateThreadSection: { name, appearance in
                Task { await model.createThreadSection(name: name, appearance: appearance) }
            },
            onUpdateThreadSection: { id, name, appearance in
                Task { await model.updateThreadSection(id: id, name: name, appearance: appearance) }
            },
            onDeleteThreadSection: { id in
                Task { await model.deleteThreadSection(id: id) }
            },
            hooksCatalog: model.hooksCatalog,
            isLoadingHooks: model.isLoadingHooks,
            hooksError: model.hooksError,
            hooksProvider: model.integrationControlPlaneProvider,
            onRefreshHooks: {
                Task { await model.refreshHooks() }
            },
            runtimeFeatures: AnyView(CodexAppRuntimeFeaturesView(model: model)),
            onBackToApp: onBackToApp
        )
        .codexAgentTheme(model.theme)
    }
}
