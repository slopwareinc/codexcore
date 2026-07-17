import XCTest
@testable import CodexCore

final class CodexFacadeTests: XCTestCase {
    func testDefaultCodexHomeIsIsolatedFromNormalCodexApp() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codexcore", isDirectory: true)
            .path

        XCTAssertEqual(CodexHome.default.path, expected)
        XCTAssertNotEqual(
            CodexHome.default.path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
                .path
        )
    }

    func testCodexHomeIsAValueAndDoesNotCreateItsDirectory() {
        let candidate = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "codexcore-home-\(UUID().uuidString)",
                isDirectory: true
            )
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))

        let home = CodexHome(path: candidate.path + "/nested/..")

        XCTAssertEqual(home.path, candidate.path)
        XCTAssertEqual(
            home.authFileURL.path,
            candidate.appendingPathComponent("auth.json").path
        )
        XCTAssertEqual(
            home.configFileURL.path,
            candidate.appendingPathComponent("config.toml").path
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
    }

    func testConfigMakesCodexHomeAndFileCredentialsAuthoritative() {
        let customHome = CodexHome(path: "/tmp/codex-home/../codex-home")

        XCTAssertEqual(CodexConfig().codexHome, .default)
        XCTAssertEqual(
            CodexConfig().environment[CodexHome.environmentKey],
            CodexHome.default.path
        )
        XCTAssertEqual(CodexConfig(codexHome: customHome).codexHome, customHome)

        let config = CodexConfig(
            codexHome: customHome,
            configOverrides: [
                #"model="gpt-test""#,
                #"cli_auth_credentials_store="keyring""#,
            ],
            environment: [CodexHome.environmentKey: "/tmp/another-home"]
        )
        XCTAssertEqual(config.environment[CodexHome.environmentKey], customHome.path)
        XCTAssertEqual(config.configOverrides, [
            #"model="gpt-test""#,
            CodexConfig.isolatedAuthConfigOverride,
        ])
    }

    func testFacadeOwnsOneSessionAndForcesIsolatedAlphaHandshake() async throws {
        let home = CodexHome(path: "/tmp/codexcore-facade-test")
        let transport = CodexFacadeTestTransport(reportedHome: home.path)
        let config = CodexConfig(
            codexHome: home,
            configOverrides: [
                #"model="test""#,
                #"cli_auth_credentials_store="keyring""#,
            ],
            environment: [CodexHome.environmentKey: "/tmp/wrong-home"],
            capabilities: .init(experimentalAPI: false),
            reconnectPolicy: .disabled
        )

        XCTAssertEqual(config.environment[CodexHome.environmentKey], home.path)
        XCTAssertEqual(config.configOverrides.last, CodexConfig.isolatedAuthConfigOverride)
        XCTAssertEqual(config.capabilities.experimentalAPI, true)

        let codex = try await Codex(transport: transport, config: config)
        XCTAssertEqual(codex.codexHome, home)
        XCTAssertEqual(codex.metadata.codexHome, home.path)
        let lifecycle = await codex.session.lifecycle
        guard case .ready = lifecycle else {
            return XCTFail("Facade must return only after its canonical session is ready")
        }

        let recordedInitializeParams = await transport.latestObjectParams(method: "initialize")
        let initializeParams = try XCTUnwrap(recordedInitializeParams)
        guard case .dictionary(let capabilities)? = initializeParams["capabilities"] else {
            return XCTFail("initialize must contain capabilities")
        }
        XCTAssertEqual(capabilities["experimentalApi"], .bool(true))

        await codex.close()
        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 1)
    }

    func testFacadeRejectsServerUsingAnotherCodexHome() async throws {
        let expected = CodexHome(path: "/tmp/codexcore-expected-home")
        let transport = CodexFacadeTestTransport(reportedHome: "/tmp/normal-codex-home")

        do {
            _ = try await Codex(
                transport: transport,
                config: .init(codexHome: expected, reconnectPolicy: .disabled)
            )
            XCTFail("A server attached to another home must be rejected")
        } catch let error as CodexSDKError {
            guard case .codexHomeMismatch(let actualExpected, let actual) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(actualExpected, expected.path)
            XCTAssertEqual(actual, "/tmp/normal-codex-home")
        }

        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 1)
    }

    func testFacadeRetriesSessionWireOverloadWithoutLegacyConnectionMapping() async throws {
        let home = CodexHome(path: "/tmp/codexcore-retry-test")
        let method = CodexAppServerClientMethod.accountRateLimitsRead.rawValue
        let transport = CodexFacadeTestTransport(
            reportedHome: home.path,
            overloadOnceForMethod: method
        )
        let codex = try await Codex(
            transport: transport,
            config: .init(codexHome: home, reconnectPolicy: .disabled)
        )

        _ = try await codex.performWithRetryOnOverload(
            CodexRequest.accountRateLimitsRead(),
            maxAttempts: 2,
            initialDelay: .zero,
            maxDelay: .zero,
            jitterRatio: 0
        )

        let requestCount = await transport.writeCount(method: method)
        XCTAssertEqual(requestCount, 2)
        await codex.close()
    }
}

private actor CodexFacadeTestTransport: CodexFrameTransport {
    private let reportedHome: String
    private let overloadOnceForMethod: String?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var outbound: [[String: CodexJSONValue]] = []
    private var writesByMethod: [String: Int] = [:]
    private(set) var closeCount = 0

    init(reportedHome: String, overloadOnceForMethod: String? = nil) {
        self.reportedHome = reportedHome
        self.overloadOnceForMethod = overloadOnceForMethod
    }

    func open() async throws -> AsyncThrowingStream<Data, Error> {
        guard continuation == nil else {
            throw CodexTransportError.connectionAlreadyOpen
        }
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }

    func write(_ frame: Data) async throws {
        let value = try JSONDecoder().decode(CodexJSONValue.self, from: frame)
        guard case .dictionary(let object) = value else {
            throw CodexJSONRPCEnvelopeError.topLevelMustBeObject
        }
        outbound.append(object)

        guard case .string(let method)? = object["method"],
              let rawID = object["id"] else { return }
        let id = try CodexJSONRPCID(jsonValue: rawID)
        writesByMethod[method, default: 0] += 1

        if method == "initialize" {
            continuation?.yield(try CodexJSONRPCCodec.encodeResult(
                id: id,
                result: .dictionary([
                    "codexHome": .string(reportedHome),
                    "platformFamily": .string("unix"),
                    "platformOs": .string("macos"),
                    "userAgent": .string("Codex Desktop/0.145.0-alpha.20 (Mac OS; arm64) test"),
                ])
            ))
        } else if method == overloadOnceForMethod {
            if writesByMethod[method] == 1 {
                continuation?.yield(try CodexJSONRPCCodec.encodeError(
                    id: id,
                    error: .init(
                        code: -32000,
                        message: "server overloaded",
                        data: .dictionary([
                            "codexErrorInfo": .string("server_overloaded")
                        ])
                    )
                ))
            } else {
                continuation?.yield(try CodexJSONRPCCodec.encodeResult(
                    id: id,
                    result: .dictionary(["rateLimits": .dictionary([:])])
                ))
            }
        }
    }

    func close() async {
        closeCount += 1
        continuation?.finish()
        continuation = nil
    }

    func latestObjectParams(method: String) -> [String: CodexJSONValue]? {
        for payload in outbound.reversed() {
            guard case .string(let candidate)? = payload["method"],
                  candidate == method else { continue }
            guard case .dictionary(let params)? = payload["params"] else { return nil }
            return params
        }
        return nil
    }

    func writeCount(method: String) -> Int {
        writesByMethod[method, default: 0]
    }
}
