import Foundation
import Observation
import CodexCore

struct CodexAppVerificationOperation<Response: Sendable>: Sendable {
    var completion: @Sendable () async throws -> Response
    var cancel: @Sendable () async throws -> Void

    init(_ operation: CodexUserVerificationOperation<Response>) {
        completion = { try await operation.completion() }
        cancel = { try await operation.cancel() }
    }

    init(
        completion: @escaping @Sendable () async throws -> Response,
        cancel: @escaping @Sendable () async throws -> Void
    ) {
        self.completion = completion
        self.cancel = cancel
    }
}

/// Runtime calls are injected separately from presentation and account lifecycle.
/// Credential inputs and verification proofs never enter observable view state.
protocol CodexAppAccountFeatureProviding: Sendable {
    func gatewayRead() async throws -> CodexSchemaGatewayOAuthReadResponse
    func gatewayLogin() async throws
    func gatewayCancel() async throws
    func bedrockDiscover() async throws -> CodexSchemaBedrockDiscoverResponse
    func bedrockSetup(profile: String?, region: String) async throws
    func login(_ params: CodexSchemaLoginAccountParams) async throws
    func providerCapabilities() async throws -> CodexSchemaModelProviderCapabilitiesReadResponse
    func workspaceMessages() async throws -> CodexSchemaGetWorkspaceMessagesResponse
    func usage() async throws -> CodexSchemaGetAccountTokenUsageResponse
    func rateLimits() async throws -> CodexSchemaGetAccountRateLimitsResponse
    func consumeCredit(_ params: CodexSchemaConsumeAccountRateLimitResetCreditParams) async throws -> CodexSchemaConsumeAccountRateLimitResetCreditResponse
    func sendCreditNudge(_ type: CodexSchemaAddCreditsNudgeCreditType) async throws -> CodexSchemaSendAddCreditsNudgeEmailResponse
    func verificationStatus() async throws -> CodexAppVerificationOperation<CodexSchemaUserVerificationStatusResponse>
    func verificationEnroll() async throws -> CodexAppVerificationOperation<CodexSchemaUserVerificationEnrollResponse>
    func verificationDelete() async throws -> CodexAppVerificationOperation<CodexSchemaUserVerificationDeleteResponse>
    func verificationVerify(_ params: CodexSchemaUserVerificationVerifyParams) async throws -> CodexAppVerificationOperation<CodexSchemaUserVerificationVerifyResponse>
}

struct CodexAppAccountRuntime: CodexAppAccountFeatureProviding {
    let codex: Codex

    func gatewayRead() async throws -> CodexSchemaGatewayOAuthReadResponse {
        try await codex.perform(CodexRequest.accountGatewayOAuthRead())
    }
    func gatewayLogin() async throws { _ = try await codex.perform(CodexRequest.accountGatewayOAuthLogin()) }
    func gatewayCancel() async throws { _ = try await codex.perform(CodexRequest.accountGatewayOAuthCancel()) }
    func bedrockDiscover() async throws -> CodexSchemaBedrockDiscoverResponse {
        try await codex.perform(CodexRequest.accountBedrockDiscover(.init(.dictionary([:]))))
    }
    func bedrockSetup(profile: String?, region: String) async throws {
        var fields: [String: CodexJSONValue] = [
            "type": .string(profile == nil ? "environment" : "profile"),
            "region": .string(region),
        ]
        if let profile { fields["profile"] = .string(profile) }
        _ = try await codex.perform(CodexRequest.accountBedrockSetup(.init(.dictionary(fields))))
    }
    func login(_ params: CodexSchemaLoginAccountParams) async throws {
        let transaction = try await codex.startLogin(params)
        let result = try await transaction.completion()
        guard result.success else {
            throw CodexRPCError(code: -32_000, message: result.error ?? "Authentication did not complete", kind: .codexRpc)
        }
    }
    func providerCapabilities() async throws -> CodexSchemaModelProviderCapabilitiesReadResponse {
        try await codex.perform(CodexRequest.modelProviderCapabilitiesRead(.init(.dictionary([:]))))
    }
    func workspaceMessages() async throws -> CodexSchemaGetWorkspaceMessagesResponse {
        try await codex.perform(CodexRequest.accountWorkspaceMessagesRead())
    }
    func usage() async throws -> CodexSchemaGetAccountTokenUsageResponse {
        try await codex.perform(CodexRequest.accountUsageRead())
    }
    func rateLimits() async throws -> CodexSchemaGetAccountRateLimitsResponse {
        try await codex.perform(CodexRequest.accountRateLimitsRead(.value(.init(supportsLunaReserve: true))))
    }
    func consumeCredit(_ params: CodexSchemaConsumeAccountRateLimitResetCreditParams) async throws -> CodexSchemaConsumeAccountRateLimitResetCreditResponse {
        try await codex.perform(CodexRequest.accountRateLimitResetCreditConsume(params))
    }
    func sendCreditNudge(_ type: CodexSchemaAddCreditsNudgeCreditType) async throws -> CodexSchemaSendAddCreditsNudgeEmailResponse {
        try await codex.perform(CodexRequest.accountSendAddCreditsNudgeEmail(.init(creditType: type)))
    }
    func verificationStatus() async throws -> CodexAppVerificationOperation<CodexSchemaUserVerificationStatusResponse> {
        .init(try await codex.startUserVerification(CodexRequest.userVerificationStatus(.init(.dictionary([:])))))
    }
    func verificationEnroll() async throws -> CodexAppVerificationOperation<CodexSchemaUserVerificationEnrollResponse> {
        .init(try await codex.startUserVerification(CodexRequest.userVerificationEnroll(.init(.dictionary([:])))))
    }
    func verificationDelete() async throws -> CodexAppVerificationOperation<CodexSchemaUserVerificationDeleteResponse> {
        .init(try await codex.startUserVerification(CodexRequest.userVerificationDelete(.init(.dictionary([:])))))
    }
    func verificationVerify(_ params: CodexSchemaUserVerificationVerifyParams) async throws -> CodexAppVerificationOperation<CodexSchemaUserVerificationVerifyResponse> {
        .init(try await codex.startUserVerification(CodexRequest.userVerificationVerify(params)))
    }
}

@Observable @MainActor
final class CodexAppAccountFeatures {
    private(set) var gateway: CodexSchemaGatewayOAuthReadResponse?
    private(set) var gatewayProbeSucceeded = false
    private(set) var isProbingGateway = false
    private(set) var isGatewayLoginActive = false
    private(set) var gatewayAuthorizationURL: URL?
    private(set) var gatewayError: String?
    private(set) var bedrock: CodexSchemaBedrockDiscoverResponse?
    private(set) var providerCapabilities: CodexSchemaModelProviderCapabilitiesReadResponse?
    private(set) var workspaceMessages: CodexSchemaGetWorkspaceMessagesResponse?
    private(set) var usage: CodexSchemaGetAccountTokenUsageResponse?
    private(set) var rateLimits: CodexSchemaGetAccountRateLimitsResponse?
    private(set) var verification: CodexSchemaUserVerificationStatusResponse?
    private(set) var enrollment: CodexSchemaUserVerificationEnrollResponse?
    private(set) var isVerificationActive = false
    private(set) var isRefreshing = false
    private(set) var isChangingProvider = false
    private(set) var isConsumingCredit = false
    private(set) var isSendingCreditNudge = false
    private(set) var errorMessage: String?
    private(set) var notice: String?
    @ObservationIgnored private var provider: (any CodexAppAccountFeatureProviding)?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var accountRevision: UInt64 = 0
    @ObservationIgnored private var gatewayLoginGeneration: UInt64 = 0
    @ObservationIgnored private var verificationGeneration: UInt64 = 0
    @ObservationIgnored private var cancelVerificationOperation: (@Sendable () async throws -> Void)?
    @ObservationIgnored private var creditRetryKeys: [String: String] = [:]
    @ObservationIgnored var onReadyForAuthenticatedRequests: (@MainActor () async -> Void)?
    @ObservationIgnored private var accountIdentity: String?

    var canUseAuthenticatedRequests: Bool {
        gatewayProbeSucceeded && (gateway?.required != true || gateway?.status == .succeeded)
    }

    /// Every connection must successfully probe gateway support before catalog
    /// or inference requests when explicitGatewayOauth is advertised.
    @discardableResult
    func connect(to provider: any CodexAppAccountFeatureProviding) async -> Bool {
        await disconnect()
        self.provider = provider
        return await refreshGateway(notifyReadiness: false)
    }

    func disconnect() async {
        generation &+= 1
        accountRevision &+= 1
        gatewayLoginGeneration &+= 1
        // Invalidate presentation immediately; native RPC cancellation may
        // wait behind a busy transport and must not delay closing that transport.
        verificationGeneration &+= 1
        let cancel = cancelVerificationOperation
        cancelVerificationOperation = nil
        isVerificationActive = false
        Task { try? await cancel?() }
        provider = nil
        gateway = nil
        gatewayProbeSucceeded = false
        isProbingGateway = false
        isGatewayLoginActive = false
        gatewayAuthorizationURL = nil
        gatewayError = nil
        bedrock = nil
        providerCapabilities = nil
        workspaceMessages = nil
        usage = nil
        rateLimits = nil
        verification = nil
        enrollment = nil
        isRefreshing = false
        isChangingProvider = false
        isConsumingCredit = false
        isSendingCreditNudge = false
        errorMessage = nil
        notice = nil
        creditRetryKeys.removeAll()
        accountIdentity = nil
    }

    @discardableResult
    func refreshGateway(notifyReadiness: Bool = true) async -> Bool {
        guard let provider, !isProbingGateway else { return gatewayProbeSucceeded }
        let expected = generation
        let wasReady = canUseAuthenticatedRequests
        isProbingGateway = true
        gatewayError = nil
        defer { if generation == expected { isProbingGateway = false } }
        do {
            let value = try await provider.gatewayRead()
            guard generation == expected, !Task.isCancelled else { return false }
            gateway = .init(error: nil, providerID: value.providerID, providerName: value.providerName,
                            required: value.required, status: value.status)
            gatewayProbeSucceeded = true
            gatewayError = value.error == nil ? nil : "Gateway sign-in requires attention. Retry or check the provider configuration."
            if notifyReadiness { notifyReadinessChange(wasReady: wasReady) }
            return true
        } catch {
            guard generation == expected else { return false }
            gatewayProbeSucceeded = false
            gatewayError = "Gateway readiness could not be checked. Retry or upgrade the Codex runtime."
            return false
        }
    }

    func applyCanonicalAccount(_ account: CanonicalAccountState) {
        let fields = account.extensions["account"]?.objectValue
        let identity = [account.authMode,
                        CodexJSONCoercion.flatString(from: fields?["email"]),
                        CodexJSONCoercion.flatString(from: fields?["accountId"])].compactMap { $0 }.joined(separator: "\u{0}")
        if let previous = accountIdentity, previous != identity {
            accountRevision &+= 1
            providerCapabilities = nil
            workspaceMessages = nil
            usage = nil
            rateLimits = nil
            creditRetryKeys.removeAll()
            isRefreshing = false
            isConsumingCredit = false
            isSendingCreditNudge = false
            notice = nil
            errorMessage = nil
            verificationGeneration &+= 1
            let cancel = cancelVerificationOperation
            cancelVerificationOperation = nil
            isVerificationActive = false
            verification = nil
            enrollment = nil
            Task { try? await cancel?() }
        }
        accountIdentity = identity
        let wasReady = canUseAuthenticatedRequests
        guard let raw = account.extensions["account/gatewayOAuth/changed"],
              let event = try? raw.decode(CodexSchemaGatewayOAuthChangedNotification.self),
              gateway?.providerID == event.providerID else { return }
        gateway?.status = event.status
        gateway?.error = nil
        gatewayError = event.error == nil ? nil : "Gateway sign-in requires attention. Retry or check the provider configuration."
        if event.status == .started, isGatewayLoginActive,
           let rawURL = event.authUrl, let url = URL(string: rawURL),
           ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
           url.host != nil, url.user == nil, url.password == nil {
            gatewayAuthorizationURL = url
        } else if event.status != .started {
            gatewayAuthorizationURL = nil
        }
        notifyReadinessChange(wasReady: wasReady)
    }

    private func notifyReadinessChange(wasReady: Bool) {
        guard !wasReady, canUseAuthenticatedRequests, let onReadyForAuthenticatedRequests else { return }
        let expected = generation
        Task { [weak self] in
            guard self?.generation == expected else { return }
            await onReadyForAuthenticatedRequests()
        }
    }

    func loginGateway() async {
        guard let provider, gatewayProbeSucceeded, gateway?.required == true, !isGatewayLoginActive else { return }
        let expected = generation
        gatewayLoginGeneration &+= 1
        let operationGeneration = gatewayLoginGeneration
        isGatewayLoginActive = true
        gatewayError = nil
        defer {
            if generation == expected, gatewayLoginGeneration == operationGeneration {
                isGatewayLoginActive = false
                gatewayAuthorizationURL = nil
            }
        }
        do {
            try await provider.gatewayLogin()
            guard generation == expected, gatewayLoginGeneration == operationGeneration else { return }
            _ = await refreshGateway()
        } catch {
            guard generation == expected, gatewayLoginGeneration == operationGeneration else { return }
            gatewayError = "Gateway sign-in did not complete. Retry when ready."
        }
    }

    func cancelGatewayLogin() async {
        guard let provider, isGatewayLoginActive else { return }
        let expected = generation
        let operationGeneration = gatewayLoginGeneration
        do {
            try await provider.gatewayCancel()
            guard expected == generation, operationGeneration == gatewayLoginGeneration else { return }
            gatewayLoginGeneration &+= 1
            isGatewayLoginActive = false
            gatewayAuthorizationURL = nil
        }
        catch {
            if expected == generation, operationGeneration == gatewayLoginGeneration {
                gatewayError = "Gateway sign-in cancellation could not be confirmed."
            }
        }
    }

    /// Optional inventories are user-triggered and do not hold startup open.
    func refreshAccountDetails() async {
        guard let provider, canUseAuthenticatedRequests, !isRefreshing else { return }
        let expected = generation
        let revision = accountRevision
        isRefreshing = true
        errorMessage = nil
        defer { if generation == expected, accountRevision == revision { isRefreshing = false } }
        // Separate failures preserve the supported portions of an account.
        async let capabilities = try? provider.providerCapabilities()
        async let messages = try? provider.workspaceMessages()
        async let usage = try? provider.usage()
        async let limits = try? provider.rateLimits()
        let values = await (capabilities, messages, usage, limits)
        guard generation == expected, accountRevision == revision, !Task.isCancelled else { return }
        providerCapabilities = values.0
        workspaceMessages = values.1
        self.usage = values.2
        rateLimits = values.3
        if values.0 == nil || values.1 == nil || values.2 == nil || values.3 == nil {
            errorMessage = "Some account details are unavailable for this provider or workspace."
        }
    }

    func discoverBedrock() async {
        guard let provider, !isChangingProvider else { return }
        let expected = generation
        do {
            let value = try await provider.bedrockDiscover()
            guard expected == generation else { return }
            bedrock = value
        } catch { if expected == generation { errorMessage = "AWS credential discovery failed. Check the provider configuration." } }
    }

    func setupBedrock(profile: String?, region: String) async -> Bool {
        await changeProvider { try await $0.bedrockSetup(profile: profile, region: region) }
    }

    func loginBedrock(_ params: CodexSchemaLoginAccountParams) async -> Bool {
        switch params {
        case .amazonBedrock, .amazonBedrockAccessKeys: break
        default: return false
        }
        return await changeProvider { try await $0.login(params) }
    }

    private func changeProvider(_ action: (any CodexAppAccountFeatureProviding) async throws -> Void) async -> Bool {
        guard let provider, !isChangingProvider else { return false }
        let expected = generation
        isChangingProvider = true
        gatewayProbeSucceeded = false
        errorMessage = nil
        await cancelVerification()
        defer { if expected == generation { isChangingProvider = false } }
        do {
            try await action(provider)
            guard expected == generation else { return false }
            notice = "Provider updated. Reconnect to load its model catalog."
            _ = await refreshGateway(notifyReadiness: false)
            return true
        } catch {
            if expected == generation { errorMessage = "Provider setup failed. Check the region, credentials, and credential-export configuration." }
            return false
        }
    }

    func refreshVerification() async {
        guard let provider else { return }
        let expected = generation
        do {
            let result = try await runVerification { try await provider.verificationStatus() }
            verification = .init(credentialID: result.credentialID, unavailableReason: result.unavailableReason)
        }
        catch { if expected == generation { recordVerificationFailure(error) } }
    }

    func enrollVerification() async {
        guard let provider else { return }
        let expected = generation
        do {
            let value = try await runVerification { try await provider.verificationEnroll() }
            enrollment = value
            notice = "Local key available. Backend registration is managed by the requesting service."
            await refreshVerification()
        } catch { if expected == generation { recordVerificationFailure(error) } }
    }

    func deleteVerification() async {
        guard let provider else { return }
        let expected = generation
        do {
            _ = try await runVerification { try await provider.verificationDelete() }
            enrollment = nil
            notice = "Local key removed. Backend revocation is managed by the requesting service."
            await refreshVerification()
        } catch { if expected == generation { recordVerificationFailure(error) } }
    }

    /// The approval owner must pass its exact challenge and already-approved
    /// display context, and discard the proof if that approval has ended.
    func verify(_ params: CodexSchemaUserVerificationVerifyParams) async throws -> CodexSchemaUserVerificationProof {
        guard let provider else { throw CancellationError() }
        return try await runVerification { try await provider.verificationVerify(params) }.proof
    }

    private func runVerification<Response: Sendable>(
        _ start: () async throws -> CodexAppVerificationOperation<Response>
    ) async throws -> Response {
        guard !isVerificationActive else { throw CancellationError() }
        let expected = generation
        verificationGeneration &+= 1
        let operationGeneration = verificationGeneration
        isVerificationActive = true
        defer {
            if operationGeneration == verificationGeneration {
                isVerificationActive = false
                cancelVerificationOperation = nil
            }
        }
        let operation = try await start()
        guard expected == generation, operationGeneration == verificationGeneration else {
            try? await operation.cancel()
            throw CancellationError()
        }
        cancelVerificationOperation = operation.cancel
        let response = try await operation.completion()
        guard expected == generation, operationGeneration == verificationGeneration, !Task.isCancelled else {
            throw CancellationError()
        }
        return response
    }

    func cancelVerification() async {
        verificationGeneration &+= 1
        let cancel = cancelVerificationOperation
        cancelVerificationOperation = nil
        isVerificationActive = false
        try? await cancel?()
    }

    private func recordVerificationFailure(_ error: Error) {
        guard !(error is CancellationError) else { return }
        // Use the closed reason fields, never native diagnostic messages.
        if let rpc = error as? CodexJSONRPCErrorObject, let data = rpc.data?.objectValue,
           let type = CodexJSONCoercion.flatString(from: data["type"]),
           let reason = CodexJSONCoercion.flatString(from: data["reason"]),
           Self.isKnownVerificationReason(type: type, reason: reason) {
            errorMessage = "User verification: \(type) (\(reason))."
        } else {
            errorMessage = "User verification is unavailable. Check local readiness and retry."
        }
    }

    private static func isKnownVerificationReason(type: String, reason: String) -> Bool {
        switch type {
        case "invalidRequest": CodexSchemaUserVerificationInvalidRequestReason.allCases.contains { $0.rawValue == reason }
        case "unavailable": CodexSchemaUserVerificationUnavailableReason.allCases.contains { $0.rawValue == reason }
        case "cancelled": CodexSchemaUserVerificationCancellationReason.allCases.contains { $0.rawValue == reason }
        case "failed": CodexSchemaUserVerificationFailureReason.allCases.contains { $0.rawValue == reason }
        default: false
        }
    }

    func consumeResetCredit(creditID: String?) async {
        guard let provider, canUseAuthenticatedRequests, !isConsumingCredit else { return }
        let expected = generation
        let revision = accountRevision
        let identity = creditID ?? "next-available"
        let key = creditRetryKeys[identity] ?? UUID().uuidString
        creditRetryKeys[identity] = key
        isConsumingCredit = true
        defer { if expected == generation, accountRevision == revision { isConsumingCredit = false } }
        do {
            let result = try await provider.consumeCredit(.init(creditID: creditID, idempotencyKey: key))
            guard expected == generation, accountRevision == revision else { return }
            creditRetryKeys.removeValue(forKey: identity)
            notice = "Reset credit: \(result.outcome.rawValue)."
            await refreshAccountDetails()
        } catch {
            if expected == generation, accountRevision == revision { errorMessage = "Credit redemption could not be confirmed. Retry uses the same operation identity." }
        }
    }

    func sendCreditNudge(_ type: CodexSchemaAddCreditsNudgeCreditType) async {
        guard let provider, canUseAuthenticatedRequests, !isSendingCreditNudge else { return }
        let expected = generation
        let revision = accountRevision
        isSendingCreditNudge = true
        defer { if expected == generation, accountRevision == revision { isSendingCreditNudge = false } }
        do {
            let response = try await provider.sendCreditNudge(type)
            guard expected == generation, accountRevision == revision else { return }
            notice = response.status == .sent ? "Workspace owner email sent." : "Email request: \(response.status.rawValue)."
        } catch { if expected == generation, accountRevision == revision { errorMessage = "Workspace owner email could not be sent." } }
    }
}
