import XCTest
@testable import CodexCore
@testable import CodexCoreApp

@MainActor
final class CodexAppRemoteControlFeaturesTests: XCTestCase {
    func testBindingObservesWithoutEnablingRemoteAccess() async {
        let provider = RemoteControlTestProvider()
        let features = CodexAppRemoteControlFeatures()
        await features.bind(provider)
        let calls = await provider.calls
        XCTAssertEqual(calls, ["observe"])
        XCTAssertNil(features.status)
        await features.bind(nil)
    }

    func testExplicitEnableUsesTemporaryChoiceAndDisableClearsPairing() async {
        let provider = RemoteControlTestProvider()
        let features = CodexAppRemoteControlFeatures()
        await features.bind(provider)
        await features.enable()
        XCTAssertEqual(features.status?.status, .connected)
        await features.startPairing()
        XCTAssertNotNil(features.pairing)
        await features.disable()
        XCTAssertEqual(features.status?.status, .disabled)
        XCTAssertNil(features.pairing)
        let writes = await provider.parameters
        XCTAssertEqual(writes["remoteControl/enable"]?.first?["ephemeral"], .bool(true))
        XCTAssertEqual(writes["remoteControl/disable"]?.first?["ephemeral"], .bool(true))
        await features.bind(nil)
    }

    func testPairingClaimClearsCodeAndReadsAllClientPages() async {
        let provider = RemoteControlTestProvider(connected: true)
        let features = CodexAppRemoteControlFeatures()
        await features.bind(provider)
        await features.refresh()
        XCTAssertEqual(features.clients.map(\.clientID), ["one", "two"])
        await features.startPairing()
        XCTAssertEqual(features.pairing?.manualPairingCode, "ABCD")
        await features.checkPairing()
        XCTAssertNil(features.pairing)
        XCTAssertEqual(features.notice, "Device paired.")
        let writes = await provider.parameters
        XCTAssertEqual(writes["remoteControl/pairing/start"]?.first?["manualCode"], .bool(true))
        XCTAssertEqual(writes["remoteControl/pairing/status"]?.first?["pairingCode"], .string("opaque-pairing-code"))
        await features.bind(nil)
    }

    func testExpiredCodeAndWrongEnvironmentAreRejectedWithoutExposure() async {
        for configuration in [RemoteControlTestProvider(connected: true, expiredPairing: true),
                              RemoteControlTestProvider(connected: true, wrongPairingEnvironment: true)] {
            let features = CodexAppRemoteControlFeatures()
            await features.bind(configuration)
            await features.refresh()
            await features.startPairing()
            XCTAssertNil(features.pairing)
            XCTAssertNotNil(features.errorMessage)
            XCTAssertFalse(features.errorMessage?.contains("opaque-pairing-code") == true)
            await features.bind(nil)
        }
    }

    func testRepeatedClientCursorFailsBoundedly() async {
        let provider = RemoteControlTestProvider(connected: true, repeatsCursor: true)
        let features = CodexAppRemoteControlFeatures()
        await features.bind(provider)
        await features.refresh()
        XCTAssertNotNil(features.errorMessage)
        let calls = await provider.calls.filter { $0 == "remoteControl/client/list" }
        XCTAssertEqual(calls.count, 2)
        await features.bind(nil)
    }

    func testRevokeUsesCurrentEnvironmentAndRefreshesClientInventory() async throws {
        let provider = RemoteControlTestProvider(connected: true)
        let features = CodexAppRemoteControlFeatures()
        await features.bind(provider)
        await features.refresh()
        let target = try XCTUnwrap(features.clients.first)
        await features.revoke(target)
        XCTAssertEqual(features.clients.map(\.clientID), ["two"])
        let writes = await provider.parameters
        XCTAssertEqual(writes["remoteControl/client/revoke"]?.first?["clientId"], .string("one"))
        XCTAssertEqual(writes["remoteControl/client/revoke"]?.first?["environmentId"], .string("environment"))
        await features.bind(nil)
    }

    func testLiveTransitionWinsOverOlderStatusRead() async throws {
        let provider = RemoteControlTestProvider(holdsStatusRead: true)
        let features = CodexAppRemoteControlFeatures()
        await features.bind(provider)
        let refresh = Task { await features.refresh() }
        for _ in 0..<500 {
            if await provider.hasStatusWaiter { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        await provider.emitConnected()
        for _ in 0..<500 {
            if features.status?.status == .connected { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        await provider.releaseStatusRead()
        await refresh.value
        XCTAssertEqual(features.status?.status, .connected)
        XCTAssertEqual(features.status?.environmentID, "environment")
        await features.bind(nil)
    }

    func testLiveConnectedTransitionWinsOverOlderEnableAcknowledgment() async throws {
        let provider = RemoteControlTestProvider(heldMethod: .remoteControlEnable)
        let features = CodexAppRemoteControlFeatures()
        await features.bind(provider)
        let enable = Task { await features.enable() }
        for _ in 0..<500 {
            if await provider.hasStatusWaiter { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        await provider.emitConnected()
        for _ in 0..<500 {
            if features.status?.status == .connected { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        await provider.releaseStatusRead()
        await enable.value
        XCTAssertEqual(features.status?.status, .connected)
        XCTAssertEqual(features.notice, "Remote control: connected.")
        await features.bind(nil)
    }

    func testHidingPairingDiscardsAnInFlightCodeResponse() async throws {
        let provider = RemoteControlTestProvider(connected: true, heldMethod: .remoteControlPairingStart)
        let features = CodexAppRemoteControlFeatures()
        await features.bind(provider)
        await features.refresh()
        let request = Task { await features.startPairing() }
        for _ in 0..<500 {
            if await provider.hasStatusWaiter { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        features.clearPairing()
        await provider.releaseStatusRead()
        await request.value
        XCTAssertNil(features.pairing)
        XCTAssertFalse(features.isBusy)
        await features.bind(nil)
    }
}

private actor RemoteControlTestProvider: CodexAppRemoteControlProviding {
    private var connected: Bool
    private let expiredPairing: Bool
    private let wrongPairingEnvironment: Bool
    private let repeatsCursor: Bool
    private let heldMethod: CodexAppServerClientMethod?
    private(set) var calls: [String] = []
    private(set) var parameters: [String: [[String: CodexJSONValue]]] = [:]
    private let events: AsyncThrowingStream<CodexSchemaRemoteControlStatusChangedNotification, Error>
    private let continuation: AsyncThrowingStream<CodexSchemaRemoteControlStatusChangedNotification, Error>.Continuation
    private var statusWaiter: CheckedContinuation<Void, Never>?
    private var revoked = Set<String>()
    var hasStatusWaiter: Bool { statusWaiter != nil }

    init(connected: Bool = false, expiredPairing: Bool = false, wrongPairingEnvironment: Bool = false,
         repeatsCursor: Bool = false, holdsStatusRead: Bool = false, heldMethod: CodexAppServerClientMethod? = nil) {
        self.connected = connected
        self.expiredPairing = expiredPairing
        self.wrongPairingEnvironment = wrongPairingEnvironment
        self.repeatsCursor = repeatsCursor
        self.heldMethod = holdsStatusRead ? .remoteControlStatusRead : heldMethod
        let pair = AsyncThrowingStream<CodexSchemaRemoteControlStatusChangedNotification, Error>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }
    func observeStatus() -> AsyncThrowingStream<CodexSchemaRemoteControlStatusChangedNotification, Error> {
        calls.append("observe")
        return events
    }
    func perform<Response: Decodable & Sendable>(_ request: CodexAppServerRequest<Response>) async throws -> Response {
        calls.append(request.method.rawValue)
        let fields = try request.encodeParameters()?.objectValue ?? [:]
        parameters[request.method.rawValue, default: []].append(fields)
        let response: CodexJSONValue
        switch request.method {
        case .remoteControlStatusRead:
            let value = statusValue()
            response = try CodexJSONValue(encoding: value)
        case .remoteControlEnable:
            connected = true
            response = try CodexJSONValue(encoding: heldMethod == .remoteControlEnable
                ? CodexSchemaRemoteControlStatusReadResponse(environmentID: "environment", installationID: "installation", serverName: "Test server", status: .connecting)
                : statusValue())
        case .remoteControlDisable:
            connected = false
            response = try CodexJSONValue(encoding: statusValue())
        case .remoteControlPairingStart:
            response = try CodexJSONValue(encoding: CodexSchemaRemoteControlPairingStartResponse(
                environmentID: wrongPairingEnvironment ? "other-environment" : "environment",
                expiresAt: Int(Date.now.timeIntervalSince1970) + (expiredPairing ? -60 : 60),
                manualPairingCode: "ABCD", pairingCode: "opaque-pairing-code"
            ))
        case .remoteControlPairingStatus:
            response = .dictionary(["claimed": .bool(true)])
        case .remoteControlClientList:
            let isFirst = fields["cursor"] == nil
            let id = isFirst ? "one" : "two"
            let data = revoked.contains(id) ? [] : [CodexSchemaRemoteControlClient(clientID: id, displayName: id)]
            response = try CodexJSONValue(encoding: CodexSchemaRemoteControlClientsListResponse(
                data: data, nextCursor: repeatsCursor || isFirst ? "next" : nil
            ))
        case .remoteControlClientRevoke:
            if case .string(let id)? = fields["clientId"] { revoked.insert(id) }
            response = .dictionary([:])
        default: throw CodexAppFeatureError.invalidInput("Unexpected test method")
        }
        if heldMethod == request.method { await withCheckedContinuation { statusWaiter = $0 } }
        return try response.decode(Response.self)
    }
    private func statusValue() -> CodexSchemaRemoteControlStatusReadResponse {
        .init(environmentID: connected ? "environment" : nil, installationID: "installation", serverName: "Test server", status: connected ? .connected : .disabled)
    }
    func emitConnected() {
        connected = true
        continuation.yield(.init(environmentID: "environment", installationID: "installation", serverName: "Test server", status: .connected))
    }
    func releaseStatusRead() { statusWaiter?.resume(); statusWaiter = nil }
}
