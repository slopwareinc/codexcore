import XCTest
@testable import CodexCore

final class CodexHomeAndRuntimeIsolationTests: XCTestCase {
    func testPrepareForLaunchCreatesAProtectedCustomDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("codex-home", isDirectory: true)
        let home = CodexHome(path: directory.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try home.prepareForLaunch()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
    }

    func testPrepareForLaunchRejectsNormalCodexHomeWithoutMutatingIt() {
        let normalCodexHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        let existedBefore = FileManager.default.fileExists(atPath: normalCodexHome.path)
        let home = CodexHome(path: normalCodexHome.path)

        XCTAssertThrowsError(try home.prepareForLaunch()) { error in
            guard case CodexHomePreparationError.protectedCodexDirectory = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(
            FileManager.default.fileExists(atPath: normalCodexHome.path),
            existedBefore
        )
    }

    func testPrepareForLaunchRejectsSymlinkAliasIntoNormalCodexHome() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let normalCodexHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: normalCodexHome
        )
        let childName = "must-not-create-\(UUID().uuidString)"
        let protectedChild = normalCodexHome.appendingPathComponent(
            childName,
            isDirectory: true
        )
        let home = CodexHome(
            path: alias.appendingPathComponent(childName, isDirectory: true).path
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: protectedChild.path))
        XCTAssertThrowsError(try home.prepareForLaunch()) { error in
            switch error {
            case CodexHomePreparationError.protectedCodexDirectory,
                 CodexHomePreparationError.symbolicLinkTraversal:
                break
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: protectedChild.path))
    }

    func testPrepareForLaunchRejectsDirectoryReplacedBySymlinkAfterInitialization() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let home = CodexHome(path: directory.path)

        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(
            at: directory,
            withDestinationURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        )

        XCTAssertThrowsError(try home.prepareForLaunch()) { error in
            switch error {
            case CodexHomePreparationError.protectedCodexDirectory,
                 CodexHomePreparationError.symbolicLinkTraversal:
                break
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSessionPreparesCustomHomeBeforeOpeningTransport() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = CodexHome(
            path: root.appendingPathComponent("new-home", isDirectory: true).path
        )
        let transport = HandshakeSequenceTransport(
            responses: [.matching(home: home)],
            pathExpectedAtOpen: home.path
        )
        let session = CodexSession(
            transport: transport,
            configuration: .init(codexHome: home, reconnectPolicy: .disabled)
        )

        _ = try await session.start()
        let observations = await transport.preparedPathObservations
        XCTAssertEqual(observations, [true])
        await session.stop()
    }

    func testMatchingPinnedRuntimeAndHomeInitializeSuccessfully() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = CodexHome(path: root.appendingPathComponent("home").path)
        let response = InitializeResponse.matching(home: home)
        let transport = HandshakeSequenceTransport(responses: [response])
        let session = CodexSession(
            transport: transport,
            configuration: .init(codexHome: home, reconnectPolicy: .disabled)
        )

        let metadata = try await session.start()
        XCTAssertEqual(metadata, response)
        await session.stop()
    }

    func testDifferentRuntimeUserAgentIsRetainedAsMetadata() async throws {
        let home = CodexHome.default
        let userAgent = "Codex Desktop/0.146.0 (Mac OS 26.5.0; arm64) dumb"
        let transport = HandshakeSequenceTransport(responses: [
            .matching(home: home, userAgent: userAgent),
        ])
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )

        let metadata = try await session.start()
        XCTAssertEqual(metadata.userAgent, userAgent)
        let lifecycle = await session.lifecycle
        XCTAssertEqual(lifecycle, .ready(connectionEpoch: 1))
        await session.stop()
    }

    func testUnparseableRuntimeUserAgentIsRetainedAsMetadata() async throws {
        let home = CodexHome.default
        let userAgent = "unexpected-app-server-identity"
        let transport = HandshakeSequenceTransport(responses: [
            .matching(home: home, userAgent: userAgent),
        ])
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )

        let metadata = try await session.start()
        XCTAssertEqual(metadata.userAgent, userAgent)
        let lifecycle = await session.lifecycle
        XCTAssertEqual(lifecycle, .ready(connectionEpoch: 1))
        await session.stop()
    }

    func testMalformedInitializeResponseIsFatalInsteadOfReconnectable() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = CodexHome(path: root.appendingPathComponent("home").path)
        let transport = HandshakeSequenceTransport(rawResponses: [
            .dictionary([
                "codexHome": .string(home.path),
                "platformFamily": .string("unix"),
                "platformOs": .string("macos"),
                // Required userAgent deliberately absent.
            ]),
        ])
        let session = CodexSession(
            transport: transport,
            configuration: .init(
                codexHome: home,
                reconnectPolicy: .init(
                    initialDelayMilliseconds: 0,
                    maximumDelayMilliseconds: 0
                )
            )
        )

        do {
            _ = try await session.start()
            XCTFail("A malformed handshake must not become ready")
        } catch is DecodingError {
            // Expected: schema incompatibility cannot heal by reconnecting to
            // the same executable.
        }
        let openCount = await transport.openCount
        XCTAssertEqual(openCount, 1)
    }

    func testLaunchArgumentsOverrideCannotDropAuthoritativeConfig() {
        let modelOverride = #"model="test-model""#
        let conflictingCredentialOverride = #"cli_auth_credentials_store="keyring""#
        let config = CodexConfig(
            launchArgumentsOverride: [
                "--config", conflictingCredentialOverride,
                "app-server", "--listen", "custom://",
            ],
            configOverrides: [modelOverride]
        )

        XCTAssertEqual(config.appServerLaunchArguments, [
            "--config", conflictingCredentialOverride,
            "--config", modelOverride,
            "--config", CodexConfig.isolatedAuthConfigOverride,
            "app-server", "--listen", "custom://",
        ])
    }

    func testMatchingRuntimeAndHomeAreRevalidatedOnReconnect() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = CodexHome(path: root.appendingPathComponent("home").path)
        let responses = [
            InitializeResponse.matching(home: home),
            InitializeResponse.matching(home: home),
        ]
        let transport = HandshakeSequenceTransport(responses: responses)
        let session = CodexSession(
            transport: transport,
            configuration: .init(
                codexHome: home,
                reconnectPolicy: .init(
                    initialDelayMilliseconds: 0,
                    maximumDelayMilliseconds: 0
                )
            )
        )

        _ = try await session.start()
        await transport.finishCurrentConnection()
        try await waitUntil {
            let lifecycle = await session.lifecycle
            return lifecycle == .ready(connectionEpoch: 2)
        }

        let openCount = await transport.openCount
        XCTAssertEqual(openCount, 2)
        await session.stop()
    }

    func testDifferentRuntimeUserAgentOnReconnectBecomesReadyAndReplacesMetadata() async throws {
        let home = CodexHome.default
        let transport = HandshakeSequenceTransport(responses: [
            .matching(home: home),
            .matching(
                home: home,
                userAgent: "Codex Desktop/0.146.0 (Mac OS 26.5.0; arm64) dumb"
            ),
        ])
        let session = CodexSession(
            transport: transport,
            configuration: .init(
                reconnectPolicy: .init(
                    initialDelayMilliseconds: 0,
                    maximumDelayMilliseconds: 0
                )
            )
        )

        _ = try await session.start()
        await transport.finishCurrentConnection()
        try await waitUntil { await session.lifecycle == .ready(connectionEpoch: 2) }

        let openCount = await transport.openCount
        let retainedUserAgent = await session.initializeResponse?.userAgent
        XCTAssertEqual(openCount, 2)
        XCTAssertEqual(
            retainedUserAgent,
            "Codex Desktop/0.146.0 (Mac OS 26.5.0; arm64) dumb"
        )
        await session.stop()
    }

    func testHomeMismatchOnReconnectStopsBeforeSecondEpochBecomesReady() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let expectedHome = CodexHome(path: root.appendingPathComponent("expected").path)
        let otherHome = CodexHome(path: root.appendingPathComponent("other").path)
        let transport = HandshakeSequenceTransport(responses: [
            .matching(home: expectedHome),
            .matching(home: otherHome),
        ])
        let session = CodexSession(
            transport: transport,
            configuration: .init(
                codexHome: expectedHome,
                reconnectPolicy: .init(
                    initialDelayMilliseconds: 0,
                    maximumDelayMilliseconds: 0
                )
            )
        )

        _ = try await session.start()
        await transport.finishCurrentConnection()
        try await waitUntil { await session.lifecycle == .stopped }

        let openCount = await transport.openCount
        let retainedHome = await session.initializeResponse?.codexHome
        XCTAssertEqual(openCount, 2)
        XCTAssertEqual(retainedHome, expectedHome.path)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let temporaryRoot = URL(
            fileURLWithPath: "/private/tmp",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        let directory = temporaryRoot
            .appendingPathComponent("codexcore-isolation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<300 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for session state")
        throw IsolationTestError.timedOut
    }
}

private enum IsolationTestError: Error {
    case timedOut
}

private func responsesUserAgent(at _: Int) -> String {
    "Codex Desktop/\(CodexPinnedRuntime.version) (Mac OS 26.5.0; arm64) dumb (CodexCoreTests; 1)"
}

private extension CodexSchemaInitializeResponse {
    static func matching(
        home: CodexHome,
        userAgent: String = responsesUserAgent(at: 0)
    ) -> Self {
        .init(
            codexHome: home.path,
            platformFamily: "unix",
            platformOs: "macos",
            userAgent: userAgent
        )
    }
}

private actor HandshakeSequenceTransport: CodexFrameTransport {
    private let responses: [CodexJSONValue]
    private let pathExpectedAtOpen: String?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var currentResponseIndex: Int?

    private(set) var openCount = 0
    private(set) var preparedPathObservations: [Bool] = []

    init(responses: [InitializeResponse], pathExpectedAtOpen: String? = nil) {
        precondition(!responses.isEmpty)
        self.responses = responses.map { try! CodexJSONValue(encoding: $0) }
        self.pathExpectedAtOpen = pathExpectedAtOpen
    }

    init(rawResponses: [CodexJSONValue], pathExpectedAtOpen: String? = nil) {
        precondition(!rawResponses.isEmpty)
        self.responses = rawResponses
        self.pathExpectedAtOpen = pathExpectedAtOpen
    }

    func open() async throws -> AsyncThrowingStream<Data, Error> {
        guard continuation == nil else {
            throw CodexTransportError.connectionAlreadyOpen
        }
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        continuation = pair.continuation
        currentResponseIndex = min(openCount, responses.count - 1)
        openCount += 1
        if let pathExpectedAtOpen {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: pathExpectedAtOpen,
                isDirectory: &isDirectory
            )
            preparedPathObservations.append(exists && isDirectory.boolValue)
        }
        return pair.stream
    }

    func write(_ frame: Data) async throws {
        let value = try JSONDecoder().decode(CodexJSONValue.self, from: frame)
        guard case .dictionary(let object) = value,
              object["method"] == .string("initialize"),
              let rawID = object["id"],
              let currentResponseIndex else {
            return
        }
        let id = try CodexJSONRPCID(jsonValue: rawID)
        let result = responses[currentResponseIndex]
        continuation?.yield(try CodexJSONRPCCodec.encodeResult(id: id, result: result))
    }

    func close() async {
        continuation?.finish()
        continuation = nil
        currentResponseIndex = nil
    }

    func finishCurrentConnection() {
        continuation?.finish()
    }
}
