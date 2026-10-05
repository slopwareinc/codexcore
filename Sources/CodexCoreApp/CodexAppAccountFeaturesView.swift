import SwiftUI
import CodexCore
import CodexCoreUI

/// Account and provider controls use explicit actions rather than startup
/// polling. All styling comes from the host's active Codex theme.
struct CodexAppAccountFeaturesView: View {
    @Environment(\.codexAgentTheme) private var theme
    @Environment(\.openURL) private var openURL
    @Bindable var features: CodexAppAccountFeatures
    let onProviderChanged: () async -> Void
    @State private var showsBedrock = false
    @State private var confirmsDelete = false
    @State private var confirmsCredit = false
    @State private var confirmsEmail = false
    @State private var creditToRedeem: CodexSchemaRateLimitResetCredit?
    @State private var creditNudgeType: CodexSchemaAddCreditsNudgeCreditType = .credits

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.lg) {
            gatewaySection
            section("Provider capabilities", symbol: "cpu") {
                if let capabilities = features.providerCapabilities {
                    capability("Web search", enabled: capabilities.webSearch)
                    capability("Image generation", enabled: capabilities.imageGeneration)
                    capability("Tool namespaces", enabled: capabilities.namespaceTools)
                } else {
                    detail("Refresh account details to read this provider's capabilities.")
                }
                HStack {
                    Button(features.isRefreshing ? "Reading account…" : "Refresh account details") {
                        Task { await features.refreshAccountDetails() }
                    }
                    .disabled(features.isRefreshing || !features.canUseAuthenticatedRequests)
                    Button("Set up Amazon Bedrock") {
                        showsBedrock = true
                        Task { await features.discoverBedrock() }
                    }
                }
            }
            usageSection
            verificationSection
            if let messages = features.workspaceMessages, messages.featureEnabled {
                section("Workspace messages", symbol: "bell") {
                    if messages.messages.isEmpty { detail("No workspace messages.") }
                    ForEach(messages.messages, id: \.messageID) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.messageType.rawValue).font(theme.fonts.label)
                            Text(message.messageBody).font(theme.fonts.body)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            if let error = features.errorMessage { CodexErrorBanner(message: error) }
            if let notice = features.notice { detail(notice) }
        }
        .foregroundStyle(theme.colors.textPrimary)
        .sheet(isPresented: $showsBedrock) {
            CodexAppBedrockSetupView(features: features, onProviderChanged: onProviderChanged)
                .frame(width: 540)
                .padding(theme.spacing.xl)
                .codexAgentTheme(theme)
        }
        .confirmationDialog("Remove the local verification key?", isPresented: $confirmsDelete) {
            Button("Remove local key", role: .destructive) { Task { await features.deleteVerification() } }
        } message: { Text("The requesting service manages backend revocation separately.") }
        .confirmationDialog("Use one rate-limit reset credit?", isPresented: $confirmsCredit) {
            Button("Use reset credit") {
                let id = creditToRedeem?.id
                creditToRedeem = nil
                Task { await features.consumeResetCredit(creditID: id) }
            }
        } message: { Text(creditToRedeem.map { "Redeem \($0.title ?? $0.id)? The runtime determines the redemption outcome." }
            ?? "The runtime determines whether a reset is available and returns the redemption outcome.") }
        .confirmationDialog(creditNudgeType == .credits ? "Email your workspace owner about credits?" : "Email your workspace owner about the usage limit?", isPresented: $confirmsEmail) {
            Button("Send email") { let type = creditNudgeType; Task { await features.sendCreditNudge(type) } }
        } message: { Text("This sends an email through the authenticated workspace's billing service.") }
        .onChange(of: features.gatewayAuthorizationURL) { _, url in
            if let url { openURL(url) }
        }
    }

    private var gatewaySection: some View {
        section("Gateway sign-in", symbol: "network.badge.shield.half.filled") {
            if let gateway = features.gateway {
                Text(gateway.providerName).font(theme.fonts.label)
                detail(gateway.required
                    ? "Status: \(gateway.status?.rawValue ?? "unavailable")"
                    : "This provider does not require gateway sign-in.")
                if gateway.required, gateway.status != .succeeded {
                    HStack {
                        Button(features.isGatewayLoginActive ? "Sign-in in progress…" : "Sign in to gateway") {
                            Task { await features.loginGateway() }
                        }
                        .disabled(features.isGatewayLoginActive || !features.gatewayProbeSucceeded)
                        if features.isGatewayLoginActive {
                            Button("Cancel") { Task { await features.cancelGatewayLogin() } }
                        }
                    }
                }
            } else { detail("Gateway readiness has not been confirmed.") }
            if let error = features.gatewayError { CodexErrorBanner(message: error) }
            Button(features.isProbingGateway ? "Checking…" : "Check gateway readiness") {
                Task { _ = await features.refreshGateway() }
            }.disabled(features.isProbingGateway)
        }
    }

    private var usageSection: some View {
        section("Account usage", symbol: "chart.bar") {
            if let usage = features.usage {
                if let tokens = usage.summary.lifetimeTokens { row("Lifetime tokens", value: tokens.formatted()) }
                if let streak = usage.summary.currentStreakDays { row("Current streak", value: "\(streak) days") }
                if let streak = usage.summary.longestStreakDays { row("Longest streak", value: "\(streak) days") }
                if let peak = usage.summary.peakDailyTokens { row("Peak daily tokens", value: peak.formatted()) }
                if let duration = usage.summary.longestRunningTurnSec { row("Longest turn", value: "\(duration.formatted()) seconds") }
                ForEach(usage.dailyUsageBuckets ?? [], id: \.startDate) { bucket in
                    row(bucket.startDate, value: "\(bucket.tokens.formatted()) tokens")
                }
            } else { detail("Usage is available when the provider supports account billing statistics.") }
            if let limits = features.rateLimits {
                let snapshots = limits.rateLimitsByLimitID ?? ["default": limits.rateLimits]
                ForEach(snapshots.keys.sorted(), id: \.self) { key in
                    if let snapshot = snapshots[key] {
                        row(snapshot.limitName ?? key, value: CodexRateLimitPresentation.summary(for: snapshot))
                        limitDetails(snapshot)
                    }
                }
                if let ordinary = limits.ordinaryUsageAllowed { capability("Ordinary usage", enabled: ordinary) }
                if let credits = limits.rateLimitResetCredits {
                    resetCredits(credits)
                }
                creditNudges(limits)
            }
        }
    }

    @ViewBuilder private func limitDetails(_ snapshot: CodexSchemaRateLimitSnapshot) -> some View {
        if let model = snapshot.normalModelSlug { detail("Normal model: \(model)") }
        if let credits = snapshot.credits {
            row("Credits", value: credits.unlimited ? "Unlimited" : credits.balance ?? (credits.hasCredits ? "Available" : "Depleted"))
        }
        if let spend = snapshot.individualLimit {
            row("Individual spend", value: "\(spend.used) of \(spend.limit) · \(spend.remainingPercent)% remaining")
            detail("Resets \(Date(timeIntervalSince1970: TimeInterval(spend.resetsAt)).formatted(date: .abbreviated, time: .shortened))")
        }
        if snapshot.spendControlReached == true { detail("Spend limit reached.") }
    }

    @ViewBuilder private func resetCredits(_ credits: CodexSchemaRateLimitResetCreditsSummary) -> some View {
        row("Reset credits available", value: String(credits.availableCount))
        ForEach(credits.credits ?? [], id: \.id) { credit in
            VStack(alignment: .leading, spacing: 4) {
                Text(credit.title ?? "Rate-limit reset").font(theme.fonts.label)
                if let description = credit.description { detail(description) }
                detail("\(credit.status.rawValue) · \(credit.resetType.rawValue)")
                if let expires = credit.expiresAt {
                    detail("Expires \(Date(timeIntervalSince1970: TimeInterval(expires)).formatted(date: .abbreviated, time: .shortened))")
                }
                if credit.status == .available {
                    Button("Redeem this credit…") { creditToRedeem = credit; confirmsCredit = true }
                        .disabled(features.isConsumingCredit || !features.canUseAuthenticatedRequests)
                }
            }
        }
        Button(features.isConsumingCredit ? "Redeeming…" : "Use next available reset credit…") {
            creditToRedeem = nil
            confirmsCredit = true
        }.disabled(credits.availableCount < 1 || features.isConsumingCredit || !features.canUseAuthenticatedRequests)
    }

    @ViewBuilder private func creditNudges(_ limits: CodexSchemaGetAccountRateLimitsResponse) -> some View {
        let snapshots = [limits.rateLimits] + Array((limits.rateLimitsByLimitID ?? [:]).values)
        let reachedTypes = snapshots.compactMap(\.rateLimitReachedType)
        if reachedTypes.contains(.workspaceOwnerCreditsDepleted) || reachedTypes.contains(.workspaceMemberCreditsDepleted) {
            Button("Ask workspace owner to add credits…") { creditNudgeType = .credits; confirmsEmail = true }
                .disabled(features.isSendingCreditNudge || !features.canUseAuthenticatedRequests)
        }
        if reachedTypes.contains(.workspaceOwnerUsageLimitReached) || reachedTypes.contains(.workspaceMemberUsageLimitReached) {
            Button("Ask workspace owner to raise the usage limit…") { creditNudgeType = .usageLimit; confirmsEmail = true }
                .disabled(features.isSendingCreditNudge || !features.canUseAuthenticatedRequests)
        }
    }

    private var verificationSection: some View {
        section("Local user verification", symbol: "touchid") {
            if let readiness = features.verification {
                if let reason = readiness.unavailableReason {
                    detail(CodexSchemaUserVerificationUnavailableReason.allCases.contains(reason)
                        ? "Unavailable: \(reason.rawValue)" : "Local verification is unavailable.")
                } else {
                    detail("Local readiness checks passed. The requesting service confirms backend registration.")
                }
                if let id = readiness.credentialID { row("Local credential", value: id) }
            } else { detail("Check biometric and account readiness without opening an OS prompt.") }
            HStack {
                Button("Check readiness") { Task { await features.refreshVerification() } }
                Button("Create or reuse local key") { Task { await features.enrollVerification() } }
                if features.verification?.credentialID != nil {
                    Button("Remove local key…", role: .destructive) { confirmsDelete = true }
                }
            }.disabled(features.isVerificationActive)
            if features.isVerificationActive {
                Button("Cancel verification") { Task { await features.cancelVerification() } }
            }
        }
    }

    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            Label(title, systemImage: symbol).font(theme.fonts.panelTitle)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.spacing.lg)
        .background(theme.colors.surface, in: RoundedRectangle(cornerRadius: theme.radii.large))
        .overlay(RoundedRectangle(cornerRadius: theme.radii.large).stroke(theme.colors.border, lineWidth: 1))
    }

    private func detail(_ value: String) -> some View {
        Text(value).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary)
    }
    private func capability(_ title: String, enabled: Bool) -> some View { row(title, value: enabled ? "Available" : "Unavailable") }
    private func row(_ title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: theme.spacing.md) {
            Text(title).font(theme.fonts.label)
            Spacer(minLength: 20)
            Text(value).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary)
                .multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}

private struct CodexAppBedrockSetupView: View {
    @Environment(\.codexAgentTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Bindable var features: CodexAppAccountFeatures
    var onProviderChanged: () async -> Void
    @State private var region = ""
    @State private var apiKey = ""
    @State private var accessKeyID = ""
    @State private var secretAccessKey = ""
    @State private var sessionToken = ""
    @State private var credentialType = 0

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.lg) {
            Text("Amazon Bedrock").font(theme.fonts.sheetTitle)
            Text("Choose a discovered AWS profile or environment credentials, or enter credentials for the selected region.")
                .font(theme.fonts.body).foregroundStyle(theme.colors.textSecondary)
            TextField("AWS region", text: $region).textFieldStyle(.roundedBorder)
            if let discovery = features.bedrock {
                ForEach(discovery.profiles, id: \.name) { profile in
                    Button("Use profile \(profile.name)") {
                        Task { await setup(profile: profile.name, region: region.nilIfBlank ?? profile.region ?? "") }
                    }.disabled(region.nilIfBlank == nil && profile.region == nil)
                }
                ForEach(Array(discovery.environmentCredentials.enumerated()), id: \.offset) { _, credential in
                    Button("Use environment \(credential.type.rawValue)") {
                        Task { await setup(profile: nil, region: region.nilIfBlank ?? credential.region ?? "") }
                    }.disabled(region.nilIfBlank == nil && credential.region == nil)
                }
            }
            Picker("Credential source", selection: $credentialType) {
                Text("Bedrock API key").tag(0)
                Text("AWS access keys").tag(1)
            }.pickerStyle(.segmented)
            if credentialType == 0 {
                SecureField("Bedrock API key", text: $apiKey).textFieldStyle(.roundedBorder)
            } else {
                SecureField("AWS access key ID", text: $accessKeyID).textFieldStyle(.roundedBorder)
                SecureField("AWS secret access key", text: $secretAccessKey).textFieldStyle(.roundedBorder)
                SecureField("Session token (optional)", text: $sessionToken).textFieldStyle(.roundedBorder)
            }
            if let error = features.errorMessage { CodexErrorBanner(message: error) }
            HStack {
                Button("Cancel") { clearCredentials(); dismiss() }
                Spacer()
                Button(features.isChangingProvider ? "Saving…" : "Use credentials") { submitCredentials() }
                    .disabled(features.isChangingProvider || region.nilIfBlank == nil || (credentialType == 0 ? apiKey.isEmpty : accessKeyID.isEmpty || secretAccessKey.isEmpty))
            }
        }
        .disabled(features.isChangingProvider)
        .onDisappear { clearCredentials() }
    }

    private func setup(profile: String?, region: String) async {
        if await features.setupBedrock(profile: profile, region: region) {
            await onProviderChanged()
            dismiss()
        }
    }

    private func submitCredentials() {
        var fields: [String: CodexJSONValue] = ["region": .string(region.trimmingCharacters(in: .whitespacesAndNewlines))]
        if credentialType == 0 {
            fields["type"] = .string("amazonBedrock")
            fields["apiKey"] = .string(apiKey)
        } else {
            fields["type"] = .string("amazonBedrockAccessKeys")
            fields["accessKeyId"] = .string(accessKeyID)
            fields["secretAccessKey"] = .string(secretAccessKey)
            if !sessionToken.isEmpty { fields["sessionToken"] = .string(sessionToken) }
        }
        guard let params = try? CodexJSONValue.dictionary(fields).decode(CodexSchemaLoginAccountParams.self) else { return }
        clearCredentials()
        Task {
            if await features.loginBedrock(params) {
                await onProviderChanged()
                dismiss()
            }
        }
    }

    private func clearCredentials() { apiKey = ""; accessKeyID = ""; secretAccessKey = ""; sessionToken = "" }
}

/// A host can present this after identifying an actual pending verification
/// request. It returns a proof only while the user's approval remains active.
struct CodexAppVerificationApprovalView: View {
    @Environment(\.codexAgentTheme) private var theme
    @Bindable var features: CodexAppAccountFeatures
    let params: CodexSchemaUserVerificationVerifyParams
    let onVerified: (CodexSchemaUserVerificationProof) -> Void
    let onCancelled: () -> Void
    @State private var task: Task<Void, Never>?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.lg) {
            Label(params.title, systemImage: "touchid").font(theme.fonts.sheetTitle)
            Text(params.description).font(theme.fonts.body)
            if let errorMessage { CodexErrorBanner(message: errorMessage) }
            HStack {
                Button("Cancel", role: .cancel) { cancel() }
                Spacer()
                Button(features.isVerificationActive ? "Verifying…" : "Approve and verify") {
                    task = Task {
                        do {
                            let proof = try await features.verify(params)
                            guard !Task.isCancelled else { return }
                            onVerified(proof)
                        } catch is CancellationError { }
                        catch { errorMessage = "Verification did not complete. Check readiness and retry." }
                    }
                }.disabled(features.isVerificationActive)
            }
        }
        .padding(theme.spacing.xl)
        .onDisappear { task?.cancel(); Task { await features.cancelVerification() } }
    }

    private func cancel() {
        task?.cancel()
        Task { await features.cancelVerification(); onCancelled() }
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
