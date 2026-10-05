import SwiftUI
import CodexCore
import CodexCoreUI

struct CodexAppEnvironmentFeaturesView: View {
    @Environment(\.codexAgentTheme) private var theme
    @Bindable var features: CodexAppEnvironmentFeatures
    @State private var environmentID = ""
    @State private var endpoint = ""
    @State private var bearerToken = ""
    @State private var timeout = ""
    @State private var validationError: String?
    @State private var confirmsInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.lg) {
            Text("Executor environments").font(theme.fonts.panelTitle)
            Text("Configure an executor by ID, then use that ID in a chat's environment selection.")
                .font(theme.fonts.body).foregroundStyle(theme.colors.textSecondary)
            TextField("Environment ID", text: $environmentID)
            HStack {
                Button("Check status") { Task { await features.refreshStatus(environmentID: environmentID) } }
                Button("Read shell information…") { confirmsInfo = true }
            }.disabled(environmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || features.isBusy)
            if let status = features.status {
                Text("\(features.environmentID ?? environmentID): \(status.status.rawValue)").font(theme.fonts.label)
                Text(statusDetail(status.status)).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary)
            }
            if let info = features.info {
                Text("Shell: \(info.shell.name) · \(info.shell.path)").font(theme.fonts.body).textSelection(.enabled)
                if let cwd = CodexJSONCoercion.flatString(from: info.cwd?.rawValue) { Text("Working directory: \(cwd)").font(theme.fonts.caption).textSelection(.enabled) }
            }
            Divider()
            Text("Add or update an executor").font(theme.fonts.label)
            TextField("Executor URL (wss://host/path)", text: $endpoint)
            SecureField("Bearer token (optional)", text: $bearerToken)
            TextField("Connection timeout in milliseconds (optional)", text: $timeout)
            Button(features.isBusy ? "Working…" : "Configure environment") { configure() }
                .disabled(features.isBusy)
            if let error = validationError ?? features.errorMessage { CodexErrorBanner(message: error) }
            if let notice = features.notice { Text(notice).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary) }
        }
        .textFieldStyle(.roundedBorder)
        .foregroundStyle(theme.colors.textPrimary)
        .confirmationDialog("Connect to read this environment's shell?", isPresented: $confirmsInfo) {
            Button("Read shell information") { Task { await features.readInfo(environmentID: environmentID) } }
        } message: { Text("Unlike checking status, this can start or recover the executor connection.") }
        .onDisappear { bearerToken = "" }
    }

    private func configure() {
        do {
            let params = try CodexAppEnvironmentFeatures.addParameters(environmentID: environmentID, endpoint: endpoint,
                                                                       bearerToken: bearerToken, timeoutMilliseconds: timeout)
            bearerToken = ""
            validationError = nil
            Task { await features.add(params) }
        } catch { validationError = (error as? CodexAppFeatureError)?.localizedDescription ?? "Check the environment settings." }
    }

    private func statusDetail(_ status: CodexSchemaEnvironmentStatusKind) -> String {
        switch status {
        case .ready: "The local environment or existing executor connection is ready."
        case .pending: "The environment is configured and has no ready connection yet."
        case .disconnected: "A connection failure was observed. Check the executor settings or explicitly read shell information to try recovery."
        case .unknown: "This environment ID is not configured."
        case .unrecognized: "The runtime returned a new environment status."
        }
    }
}
