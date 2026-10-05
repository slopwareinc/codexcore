import XCTest
import CodexCore
@testable import CodexCoreApp

@MainActor
final class CodexAppAccountFeaturesTests: XCTestCase {
    func testGatewayProbeIsRequiredEvenForProvidersWithoutGateway() async {
        let provider = AccountFeatureTestProvider()
        let features = CodexAppAccountFeatures()
        XCTAssertFalse(features.canUseAuthenticatedRequests)
        let success = await features.connect(to: provider)
        XCTAssertTrue(success)
        XCTAssertTrue(features.canUseAuthenticatedRequests)
        await features.disconnect()
        XCTAssertFalse(features.gatewayProbeSucceeded)
        XCTAssertFalse(features.canUseAuthenticatedRequests)
    }

    func testFailedProbeBlocksAccountInventoriesWithoutFallback() async {
        let provider = AccountFeatureTestProvider(failsProbe: true)
        let features = CodexAppAccountFeatures()
        let success = await features.connect(to: provider)
        await features.refreshAccountDetails()
        XCTAssertFalse(success)
        XCTAssertFalse(features.canUseAuthenticatedRequests)
        let calls = await provider.calls
        XCTAssertEqual(calls, ["gatewayRead"])
        XCTAssertNotNil(features.gatewayError)
    }

    func testRetryAfterFailedProbeNotifiesHostOnceWithoutStartupCallback() async {
        let provider = AccountFeatureTestProvider(failsProbe: true)
        let features = CodexAppAccountFeatures()
        var readinessCount = 0
        features.onReadyForAuthenticatedRequests = { readinessCount += 1 }
        _ = await features.connect(to: provider)
        XCTAssertEqual(readinessCount, 0)
        await provider.allowProbe()
        _ = await features.refreshGateway()
        _ = await features.refreshGateway()
        await Task.yield()
        XCTAssertTrue(features.canUseAuthenticatedRequests)
        XCTAssertEqual(readinessCount, 1)
    }

    func testGatewayReadinessTransitionHydratesOnceAndRejectsUnrelatedProviderEvents() async throws {
        let provider = AccountFeatureTestProvider(requiresGateway: true)
        let features = CodexAppAccountFeatures()
        var refreshCount = 0
        features.onReadyForAuthenticatedRequests = { refreshCount += 1 }
        _ = await features.connect(to: provider)
        XCTAssertFalse(features.canUseAuthenticatedRequests)
        features.applyCanonicalAccount(try accountEvent(providerID: "other", status: .succeeded))
        XCTAssertFalse(features.canUseAuthenticatedRequests)
        features.applyCanonicalAccount(try accountEvent(providerID: "gateway", status: .succeeded))
        features.applyCanonicalAccount(try accountEvent(providerID: "gateway", status: .succeeded))
        await Task.yield()
        XCTAssertTrue(features.canUseAuthenticatedRequests)
        XCTAssertEqual(refreshCount, 1)
    }

    func testCanceledGatewayLoginCannotResetItsReplacementFlow() async throws {
        let provider = AccountFeatureTestProvider(requiresGateway: true, holdsGatewayLogin: true)
        let features = CodexAppAccountFeatures()
        _ = await features.connect(to: provider)
        let first = Task { await features.loginGateway() }
        try await wait { await provider.gatewayWaiterCount == 1 }
        await features.cancelGatewayLogin()
        XCTAssertFalse(features.isGatewayLoginActive)
        XCTAssertNil(features.gatewayAuthorizationURL)
        let second = Task { await features.loginGateway() }
        try await wait { await provider.gatewayWaiterCount == 2 }
        await provider.finishGatewayLogin(index: 0)
        await first.value
        XCTAssertTrue(features.isGatewayLoginActive)
        await provider.finishGatewayLogin(index: 1)
        await second.value
        XCTAssertFalse(features.isGatewayLoginActive)
        let calls = await provider.calls
        XCTAssertEqual(calls.filter { $0 == "gatewayRead" }.count, 2)
    }

    func testAccountRefreshPreservesMultiBucketUsageAndDoesNotSendEmailOrConsumeCredit() async {
        let provider = AccountFeatureTestProvider()
        let features = CodexAppAccountFeatures()
        _ = await features.connect(to: provider)
        await features.refreshAccountDetails()
        XCTAssertEqual(features.usage?.summary.lifetimeTokens, 1234)
        XCTAssertEqual(features.usage?.dailyUsageBuckets?.count, 2)
        XCTAssertEqual(features.rateLimits?.rateLimitsByLimitID?.count, 2)
        XCTAssertEqual(features.providerCapabilities?.imageGeneration, true)
        XCTAssertEqual(features.workspaceMessages?.messages.count, 1)
        let calls = await provider.calls
        XCTAssertFalse(calls.contains("consumeCredit"))
        XCTAssertFalse(calls.contains("sendCreditNudge"))
    }

    func testAmbiguousCreditRedemptionRetriesWithSameIdempotencyKey() async {
        let provider = AccountFeatureTestProvider(failsFirstRedemption: true)
        let features = CodexAppAccountFeatures()
        _ = await features.connect(to: provider)
        await features.consumeResetCredit(creditID: "credit")
        XCTAssertNotNil(features.errorMessage)
        await features.consumeResetCredit(creditID: "credit")
        let attempts = await provider.creditAttempts
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[0].creditID, "credit")
        XCTAssertEqual(attempts[0].idempotencyKey, attempts[1].idempotencyKey)
        XCTAssertEqual(features.notice, "Reset credit: reset.")
    }

    func testVerificationCancellationDiscardsProofEvenWhenNativeWorkerCompletesLate() async throws {
        let provider = AccountFeatureTestProvider()
        let features = CodexAppAccountFeatures()
        _ = await features.connect(to: provider)
        let request = Task { try await features.verify(.init(challenge: "aGVsbG8", description: "Approve a service request", title: "Verify")) }
        try await wait { await provider.hasProofWaiter }
        await features.cancelVerification()
        await provider.completeProof()
        do { _ = try await request.value; XCTFail("Late proof must not escape canceled approval") }
        catch is CancellationError { }
        let cancellationCount = await provider.verificationCancellationCount
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertFalse(features.isVerificationActive)
    }

    func testAccountIdentityChangeClearsInventoryAndDiscardsLateProof() async throws {
        let provider = AccountFeatureTestProvider()
        let features = CodexAppAccountFeatures()
        _ = await features.connect(to: provider)
        features.applyCanonicalAccount(.init(authMode: "chatgpt", extensions: ["account": .dictionary(["email": .string("first@example.test")])]))
        await features.refreshAccountDetails()
        let request = Task { try await features.verify(.init(challenge: "aGVsbG8", description: "Request", title: "Verify")) }
        try await wait { await provider.hasProofWaiter }
        features.applyCanonicalAccount(.init(authMode: "chatgpt", extensions: ["account": .dictionary(["email": .string("second@example.test")])]))
        XCTAssertNil(features.rateLimits)
        XCTAssertNil(features.usage)
        await provider.completeProof()
        do { _ = try await request.value; XCTFail("A proof captured for the previous identity must be discarded") }
        catch is CancellationError { }
        XCTAssertNil(features.verification)
    }

    func testNativeVerificationFailureDisplaysOnlyKnownClosedReason() async {
        for (type, reason, expected) in [("failed", "providerError", "User verification: failed (providerError)."),
                                        ("failed", "secret-native-diagnostic", "User verification is unavailable. Check local readiness and retry.")] {
            let error = CodexJSONRPCErrorObject(code: -32000, message: "private native details", data: .dictionary(["type": .string(type), "reason": .string(reason)]))
            let provider = AccountFeatureTestProvider(verificationError: error)
            let features = CodexAppAccountFeatures()
            _ = await features.connect(to: provider)
            await features.refreshVerification()
            XCTAssertEqual(features.errorMessage, expected)
            XCTAssertFalse(features.errorMessage?.contains("private") == true)
            XCTAssertFalse(features.errorMessage?.contains("secret") == true)
        }
    }

    func testBillingMutationIsBlockedAfterGatewayReadinessRevocation() async throws {
        let provider = AccountFeatureTestProvider(requiresGateway: true)
        let features = CodexAppAccountFeatures()
        _ = await features.connect(to: provider)
        features.applyCanonicalAccount(try accountEvent(providerID: "gateway", status: .succeeded))
        await features.refreshAccountDetails()
        features.applyCanonicalAccount(try accountEvent(providerID: "gateway", status: .notReady))
        await features.consumeResetCredit(creditID: nil)
        await features.sendCreditNudge(.credits)
        let calls = await provider.calls
        XCTAssertFalse(calls.contains("consumeCredit"))
        XCTAssertFalse(calls.contains("sendCreditNudge"))
    }

    func testDisconnectInvalidatesVerificationWithoutWaitingForNativePrompt() async throws {
        let provider = AccountFeatureTestProvider()
        let features = CodexAppAccountFeatures()
        _ = await features.connect(to: provider)
        let request = Task { try await features.verify(.init(challenge: "aGVsbG8", description: "Request", title: "Verify")) }
        try await wait { await provider.hasProofWaiter }
        await features.disconnect()
        XCTAssertFalse(features.isVerificationActive)
        XCTAssertNil(features.verification)
        await provider.completeProof()
        do { _ = try await request.value; XCTFail("Disconnect must discard the proof") }
        catch is CancellationError { }
        XCTAssertNil(features.errorMessage)
    }

    func testLocalEnrollmentDoesNotClaimBackendRegistration() async {
        let provider = AccountFeatureTestProvider()
        let features = CodexAppAccountFeatures()
        _ = await features.connect(to: provider)
        await features.enrollVerification()
        XCTAssertEqual(features.enrollment?.credentialID, "local-key")
        XCTAssertEqual(features.verification?.credentialID, "local-key")
        XCTAssertTrue(features.notice?.contains("Backend registration is managed") == true)
        await features.deleteVerification()
        XCTAssertNil(features.enrollment)
        XCTAssertTrue(features.notice?.contains("Backend revocation is managed") == true)
    }

    func testBedrockSetupUsesExplicitSourceAndRequiresCatalogReconnect() async {
        let provider = AccountFeatureTestProvider()
        let features = CodexAppAccountFeatures()
        _ = await features.connect(to: provider)
        await features.discoverBedrock()
        XCTAssertEqual(features.bedrock?.profiles.first?.name, "development")
        let result = await features.setupBedrock(profile: "development", region: "us-east-1")
        XCTAssertTrue(result)
        let selection = await provider.bedrockSelection
        XCTAssertEqual(selection?.profile, "development")
        XCTAssertEqual(selection?.region, "us-east-1")
        XCTAssertTrue(features.notice?.contains("Reconnect") == true)
    }

    private func accountEvent(providerID: String, status: CodexSchemaGatewayOAuthStatus) throws -> CanonicalAccountState {
        .init(extensions: ["account/gatewayOAuth/changed": try CodexJSONValue(encoding: CodexSchemaGatewayOAuthChangedNotification(providerID: providerID, status: status))])
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw AccountFeatureTestError.timeout
    }
}

private enum AccountFeatureTestError: Error { case unsupported, uncertain, timeout }

private actor AccountFeatureTestProvider: CodexAppAccountFeatureProviding {
    private var failsProbe: Bool
    let requiresGateway: Bool
    let failsFirstRedemption: Bool
    private let verificationError: CodexJSONRPCErrorObject?
    private let holdsGatewayLogin: Bool
    private var gatewayWaiters: [CheckedContinuation<Void, Never>] = []
    var gatewayWaiterCount: Int { gatewayWaiters.count }
    private(set) var calls: [String] = []
    private(set) var creditAttempts: [CodexSchemaConsumeAccountRateLimitResetCreditParams] = []
    private(set) var verificationCancellationCount = 0
    private(set) var bedrockSelection: (profile: String?, region: String)?
    private var proofWaiter: CheckedContinuation<CodexSchemaUserVerificationVerifyResponse, Error>?
    var hasProofWaiter: Bool { proofWaiter != nil }

    init(failsProbe: Bool = false, requiresGateway: Bool = false, failsFirstRedemption: Bool = false,
         verificationError: CodexJSONRPCErrorObject? = nil, holdsGatewayLogin: Bool = false) {
        self.failsProbe = failsProbe
        self.requiresGateway = requiresGateway
        self.failsFirstRedemption = failsFirstRedemption
        self.verificationError = verificationError
        self.holdsGatewayLogin = holdsGatewayLogin
    }
    func allowProbe() { failsProbe = false }
    func gatewayRead() throws -> CodexSchemaGatewayOAuthReadResponse {
        calls.append("gatewayRead")
        if failsProbe { throw AccountFeatureTestError.unsupported }
        return .init(providerID: "gateway", providerName: "Test provider", required: requiresGateway, status: requiresGateway ? .notReady : nil)
    }
    func gatewayLogin() async throws {
        calls.append("gatewayLogin")
        if holdsGatewayLogin { await withCheckedContinuation { gatewayWaiters.append($0) } }
    }
    func finishGatewayLogin(index: Int) { gatewayWaiters[index].resume() }
    func gatewayCancel() throws { calls.append("gatewayCancel") }
    func bedrockDiscover() -> CodexSchemaBedrockDiscoverResponse {
        .init(environmentCredentials: [.init(region: "us-east-1", type: .accessKeys)], profiles: [.init(name: "development", region: "us-east-1")])
    }
    func bedrockSetup(profile: String?, region: String) { bedrockSelection = (profile, region) }
    func login(_ params: CodexSchemaLoginAccountParams) { calls.append("login") }
    func providerCapabilities() -> CodexSchemaModelProviderCapabilitiesReadResponse {
        calls.append("providerCapabilities")
        return .init(imageGeneration: true, namespaceTools: true, webSearch: false)
    }
    func workspaceMessages() -> CodexSchemaGetWorkspaceMessagesResponse {
        calls.append("workspaceMessages")
        return .init(featureEnabled: true, messages: [.init(messageBody: "Workspace notice", messageID: "message", messageType: .unrecognized("notice"))])
    }
    func usage() -> CodexSchemaGetAccountTokenUsageResponse {
        calls.append("usage")
        return .init(dailyUsageBuckets: [.init(startDate: "2026-10-04", tokens: 500), .init(startDate: "2026-10-05", tokens: 734)], summary: .init(lifetimeTokens: 1234))
    }
    func rateLimits() -> CodexSchemaGetAccountRateLimitsResponse {
        calls.append("rateLimits")
        return .init(rateLimitResetCredits: .init(availableCount: 2), rateLimits: .init(), rateLimitsByLimitID: ["regular": .init(), "reserve": .init()])
    }
    func consumeCredit(_ params: CodexSchemaConsumeAccountRateLimitResetCreditParams) throws -> CodexSchemaConsumeAccountRateLimitResetCreditResponse {
        calls.append("consumeCredit")
        creditAttempts.append(params)
        if failsFirstRedemption && creditAttempts.count == 1 { throw AccountFeatureTestError.uncertain }
        return .init(outcome: .reset)
    }
    func sendCreditNudge(_ type: CodexSchemaAddCreditsNudgeCreditType) -> CodexSchemaSendAddCreditsNudgeEmailResponse {
        calls.append("sendCreditNudge")
        return .init(status: .sent)
    }
    func verificationStatus() -> CodexAppVerificationOperation<CodexSchemaUserVerificationStatusResponse> {
        if let error = verificationError { return .init(completion: { throw error }, cancel: {}) }
        return .init(completion: { .init(credentialID: "local-key") }, cancel: {})
    }
    func verificationEnroll() -> CodexAppVerificationOperation<CodexSchemaUserVerificationEnrollResponse> {
        .init(completion: { .init(algorithm: "ecdsaP256Sha256X962", credentialID: "local-key", publicKey: "public-metadata") }, cancel: {})
    }
    func verificationDelete() -> CodexAppVerificationOperation<CodexSchemaUserVerificationDeleteResponse> {
        .init(completion: { .init(.dictionary([:])) }, cancel: {})
    }
    func verificationVerify(_ params: CodexSchemaUserVerificationVerifyParams) -> CodexAppVerificationOperation<CodexSchemaUserVerificationVerifyResponse> {
        .init(completion: { try await self.awaitProof() }, cancel: { await self.recordCancellation() })
    }
    private func awaitProof() async throws -> CodexSchemaUserVerificationVerifyResponse {
        try await withCheckedThrowingContinuation { proofWaiter = $0 }
    }
    private func recordCancellation() { verificationCancellationCount += 1 }
    func completeProof() {
        proofWaiter?.resume(returning: .init(proof: .init(credentialID: "local-key", signature: "proof")))
        proofWaiter = nil
    }
}
