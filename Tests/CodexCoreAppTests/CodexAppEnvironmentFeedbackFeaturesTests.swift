import XCTest
@testable import CodexCore
@testable import CodexCoreApp

@MainActor
final class CodexAppEnvironmentFeedbackFeaturesTests: XCTestCase {
    func testBindingDoesNotConnectAnExecutorOrUploadFeedback() async {
        let provider = EnvironmentFeedbackTestProvider()
        let environment = CodexAppEnvironmentFeatures()
        let feedback = CodexAppFeedbackFeatures()
        environment.bind(provider)
        feedback.bind(provider)
        let calls = await provider.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testEnvironmentBearerRequiresSecureOrLiteralLoopbackTransport() throws {
        for endpoint in ["wss://executor.example/socket", "ws://localhost:8000", "ws://127.4.3.2/socket", "ws://[::1]:8000"] {
            let params = try CodexAppEnvironmentFeatures.addParameters(environmentID: " remote ", endpoint: endpoint,
                bearerToken: "token", timeoutMilliseconds: "1200")
            XCTAssertEqual(params.environmentID, "remote")
            XCTAssertEqual(params.authBearerToken, "token")
            XCTAssertEqual(params.connectTimeoutMs, 1200)
        }
        for endpoint in ["ws://executor.example", "ws://localhost.example", "ws://127.evil.example", "https://executor.example", "wss://user:token@host"] {
            XCTAssertThrowsError(try CodexAppEnvironmentFeatures.addParameters(environmentID: "remote", endpoint: endpoint,
                bearerToken: "secret", timeoutMilliseconds: ""))
        }
        XCTAssertThrowsError(try CodexAppEnvironmentFeatures.addParameters(environmentID: "remote", endpoint: "wss://host",
            bearerToken: "token\r\nheader", timeoutMilliseconds: ""))
    }

    func testAddOmitsOptionalDefaultsAndDoesNotStartOrReadEnvironment() async throws {
        let provider = EnvironmentFeedbackTestProvider()
        let features = CodexAppEnvironmentFeatures()
        features.bind(provider)
        let params = try CodexAppEnvironmentFeatures.addParameters(environmentID: "remote", endpoint: "ws://host/socket",
            bearerToken: "", timeoutMilliseconds: "")
        await features.add(params)
        let calls = await provider.calls
        XCTAssertEqual(calls, ["environment/add"])
        let fields = await provider.parameters["environment/add"]?.first
        XCTAssertNil(fields?["authBearerToken"])
        XCTAssertNil(fields?["connectTimeoutMs"])
        XCTAssertEqual(features.environmentID, "remote")
        XCTAssertNil(features.status)
        XCTAssertNil(features.info)
    }

    func testStatusNeverForceConnectsAndDoesNotRetainNativeSecrets() async {
        let provider = EnvironmentFeedbackTestProvider()
        let features = CodexAppEnvironmentFeatures()
        features.bind(provider)
        await features.refreshStatus(environmentID: " remote ")
        let calls = await provider.calls
        XCTAssertEqual(calls, ["environment/status"])
        XCTAssertEqual(features.status?.status, .disconnected)
        XCTAssertNil(features.status?.error)
        XCTAssertNil(features.info)
        await features.readInfo(environmentID: "remote")
        XCTAssertEqual(features.info?.shell.name, "zsh")
    }

    func testDisconnectDiscardsLateShellResponse() async throws {
        let provider = EnvironmentFeedbackTestProvider(heldMethod: .environmentInfo)
        let features = CodexAppEnvironmentFeatures()
        features.bind(provider)
        let operation = Task { await features.readInfo(environmentID: "remote") }
        try await waitForHeldCall(provider)
        features.bind(nil)
        await provider.release()
        await operation.value
        XCTAssertNil(features.info)
        XCTAssertNil(features.environmentID)
        XCTAssertFalse(features.isBusy)
    }

    func testFeedbackPayloadDefaultsDoNotIncludeLogsOrAttachments() throws {
        let params = try CodexAppFeedbackFeatures.parameters(category: .goodResult, reason: " helpful ", threadID: nil,
            includeLogs: false, extraFiles: "", tags: "")
        XCTAssertEqual(params.classification, "good_result")
        XCTAssertEqual(params.reason, "helpful")
        XCTAssertEqual(params.includeLogs, false)
        XCTAssertNil(params.threadID)
        XCTAssertNil(params.extraLogFiles)
        XCTAssertNil(params.tags)
    }

    func testFeedbackAdvancedFieldsAreLosslessAndFilesNeedConsent() throws {
        let params = try CodexAppFeedbackFeatures.parameters(category: .safetyCheck, reason: "", threadID: "chat",
            includeLogs: true, extraFiles: "/tmp/one.log\n/tmp/two.log\n/tmp/one.log", tags: "turn_id=turn\ncustom=a=b")
        XCTAssertEqual(params.classification, "safety_check")
        XCTAssertNil(params.reason)
        XCTAssertEqual(params.extraLogFiles, ["/tmp/one.log", "/tmp/two.log"])
        XCTAssertEqual(params.tags, ["turn_id": "turn", "custom": "a=b"])
        XCTAssertThrowsError(try CodexAppFeedbackFeatures.parameters(category: .bug, reason: "", threadID: nil,
            includeLogs: false, extraFiles: "/tmp/one.log", tags: ""))
        for tags in ["missing_separator", "=empty_key", "duplicate=1\nduplicate=2"] {
            XCTAssertThrowsError(try CodexAppFeedbackFeatures.parameters(category: .bug, reason: "", threadID: nil,
                includeLogs: false, extraFiles: "", tags: tags))
        }
    }

    func testFeedbackUploadsOnlyExactReviewedPayload() async throws {
        let provider = EnvironmentFeedbackTestProvider()
        let features = CodexAppFeedbackFeatures()
        features.bind(provider)
        let params = try CodexAppFeedbackFeatures.parameters(category: .badResult, reason: "Example", threadID: "chat",
            includeLogs: true, extraFiles: "/tmp/one.log", tags: "turn_id=turn")
        await features.upload(params)
        let calls = await provider.calls
        XCTAssertEqual(calls, ["feedback/upload"])
        let fields = await provider.parameters["feedback/upload"]?.first
        XCTAssertEqual(fields?["classification"], .string("bad_result"))
        XCTAssertEqual(fields?["includeLogs"], .bool(true))
        XCTAssertEqual(fields?["threadId"], .string("chat"))
        XCTAssertEqual(features.receipt?.threadID, "receipt")
        XCTAssertEqual(features.receipt?.promptHash, "hash")
    }

    func testFeedbackFailureNeverAutomaticallyRetriesOrDisplaysNote() async {
        let provider = EnvironmentFeedbackTestProvider(failsFeedback: true)
        let features = CodexAppFeedbackFeatures()
        features.bind(provider)
        await features.upload(.init(classification: "bug", reason: "private feedback"))
        let calls = await provider.calls
        XCTAssertEqual(calls, ["feedback/upload"])
        XCTAssertNotNil(features.errorMessage)
        XCTAssertFalse(features.errorMessage?.contains("private feedback") == true)
        XCTAssertNil(features.receipt)
    }

    func testFeedbackDisconnectDropsLateReceiptAndConcurrentUpload() async throws {
        let provider = EnvironmentFeedbackTestProvider(heldMethod: .feedbackUpload)
        let features = CodexAppFeedbackFeatures()
        features.bind(provider)
        let operation = Task { await features.upload(.init(classification: "bug")) }
        try await waitForHeldCall(provider)
        await features.upload(.init(classification: "other"))
        features.bind(nil)
        await provider.release()
        await operation.value
        XCTAssertNil(features.receipt)
        XCTAssertFalse(features.isUploading)
        let calls = await provider.calls
        XCTAssertEqual(calls, ["feedback/upload"])
    }

    private func waitForHeldCall(_ provider: EnvironmentFeedbackTestProvider) async throws {
        for _ in 0..<500 {
            if await provider.hasWaiter { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Provider did not receive the held call")
    }
}

private actor EnvironmentFeedbackTestProvider: CodexAppRuntimeProviding {
    private let heldMethod: CodexAppServerClientMethod?
    private let failsFeedback: Bool
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var calls: [String] = []
    private(set) var parameters: [String: [[String: CodexJSONValue]]] = [:]
    var hasWaiter: Bool { waiter != nil }

    init(heldMethod: CodexAppServerClientMethod? = nil, failsFeedback: Bool = false) {
        self.heldMethod = heldMethod
        self.failsFeedback = failsFeedback
    }

    func perform<Response: Decodable & Sendable>(_ request: CodexAppServerRequest<Response>) async throws -> Response {
        calls.append(request.method.rawValue)
        parameters[request.method.rawValue, default: []].append(try request.encodeParameters()?.objectValue ?? [:])
        if heldMethod == request.method { await withCheckedContinuation { waiter = $0 } }
        let response: CodexJSONValue
        switch request.method {
        case .environmentAdd: response = .dictionary([:])
        case .environmentStatus: response = try .init(encoding: CodexSchemaEnvironmentStatusResponse(error: "native bearer=secret", status: .disconnected))
        case .environmentInfo: response = try .init(encoding: CodexSchemaEnvironmentInfoResponse(shell: .init(name: "zsh", path: "/bin/zsh")))
        case .feedbackUpload:
            if failsFeedback { throw CodexJSONRPCErrorObject(code: -32000, message: "private feedback") }
            response = try .init(encoding: CodexSchemaFeedbackUploadResponse(promptHash: "hash", threadID: "receipt"))
        default: throw CodexAppFeatureError.invalidInput("Unexpected test request")
        }
        return try response.decode(Response.self)
    }
    func release() { waiter?.resume(); waiter = nil }
}
