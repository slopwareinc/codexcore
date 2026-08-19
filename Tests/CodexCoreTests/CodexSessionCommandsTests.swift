import XCTest
@testable import CodexCore

final class CodexSessionCommandsTests: XCTestCase {
    func testGeneratedSurfaceExhaustivelyCoversPostHandshakeMethods() {
        let expected = Set(CodexAppServerClientMethod.allCases).subtracting([.initialize])

        XCTAssertEqual(CodexRequest.supportedMethods, expected)
        XCTAssertEqual(
            CodexRequest.nullableParameterMethods,
            [.remoteControlEnable, .remoteControlDisable]
        )
    }

    func testGA147RequestFactoriesEncodePluginSearchAndThreadSections() throws {
        let search = CodexRequest.pluginSearch(.init(
            cursor: "next",
            cwds: [CodexSchemaAbsolutePathBuf(.string("/tmp/project"))],
            limit: 25,
            scope: .workspace,
            searchTerm: "github"
        ))
        XCTAssertEqual(search.method, .pluginSearch)
        XCTAssertEqual(
            try search.encodeParameters(),
            .dictionary([
                "cursor": .string("next"),
                "cwds": .array([.string("/tmp/project")]),
                "limit": .int(25),
                "scope": .string("workspace"),
                "searchTerm": .string("github"),
            ])
        )

        let move = CodexRequest.threadSectionMove(.init(
            beforeThreadID: "thread-2",
            sectionID: "section-1",
            threadID: "thread-1"
        ))
        XCTAssertEqual(move.method, .threadSectionMove)
        XCTAssertEqual(
            try move.encodeParameters(),
            .dictionary([
                "beforeThreadId": .string("thread-2"),
                "sectionId": .string("section-1"),
                "threadId": .string("thread-1"),
            ])
        )
    }

    func testGA145RequestFactoriesEncodeAppAndThreadSearchMethods() throws {
        let occurrenceSearch = CodexRequest.threadSearchOccurrences(.init(
            limit: 50,
            searchTerm: "needle",
            threadID: "thread-1"
        ))
        XCTAssertEqual(occurrenceSearch.method, .threadSearchOccurrences)
        XCTAssertEqual(
            try occurrenceSearch.encodeParameters(),
            .dictionary([
                "limit": .int(50),
                "searchTerm": .string("needle"),
                "threadId": .string("thread-1"),
            ])
        )

        let installedApps = CodexRequest.appInstalled(.init(
            forceRefresh: true,
            threadID: "thread-1"
        ))
        XCTAssertEqual(installedApps.method, .appInstalled)
        XCTAssertEqual(
            try installedApps.encodeParameters(),
            .dictionary([
                "forceRefresh": .bool(true),
                "threadId": .string("thread-1"),
            ])
        )
    }

    func testRequestFactoryPreservesMethodAndGeneratedParameters() throws {
        let request = CodexRequest.threadResume(
            .init(
                initialTurnsPage: .init(itemsView: .full, limit: 25, sortDirection: .desc),
                threadID: "thread-1"
            )
        )

        XCTAssertEqual(request.method, .threadResume)
        guard case .dictionary(let params)? = try request.encodeParameters() else {
            return XCTFail("thread/resume parameters must encode as an object")
        }
        XCTAssertEqual(params["threadId"], .string("thread-1"))
        guard case .dictionary(let page)? = params["initialTurnsPage"] else {
            return XCTFail("initialTurnsPage must remain nested")
        }
        XCTAssertEqual(page["itemsView"], .string("full"))
        XCTAssertEqual(page["limit"], .int(25))
        XCTAssertEqual(page["sortDirection"], .string("desc"))
    }

    func testNullableParametersKeepOmissionNullAndEmptyObjectDistinct() throws {
        let omitted = CodexRequest.remoteControlEnable()
        let null = CodexRequest.remoteControlEnable(.null)
        let value = CodexRequest.remoteControlEnable(.value(.init()))

        XCTAssertEqual(omitted.method, .remoteControlEnable)
        XCTAssertNil(try omitted.encodeParameters())
        XCTAssertEqual(try null.encodeParameters(), .null)
        XCTAssertEqual(try value.encodeParameters(), .dictionary([:]))
    }

    func testTurnInterruptUsesCompositeProtocolIdentity() throws {
        let request = CodexRequest.turnInterrupt(
            .init(threadID: "thread-A", turnID: "turn-shared")
        )

        XCTAssertEqual(request.method, .turnInterrupt)
        XCTAssertEqual(
            try request.encodeParameters(),
            .dictionary([
                "threadId": .string("thread-A"),
                "turnId": .string("turn-shared"),
            ])
        )
    }

    func testLoginAccountParamsPreservesAllPinnedUnionArmsAndUnknownFields() throws {
        let fixtures: [(String, CodexJSONValue)] = [
            ("apiKey", .dictionary([
                "type": .string("apiKey"),
                "apiKey": .string("key"),
            ])),
            ("chatgpt", .dictionary([
                "type": .string("chatgpt"),
            ])),
            ("chatgptDeviceCode", .dictionary([
                "type": .string("chatgptDeviceCode"),
            ])),
            ("chatgptAuthTokens", .dictionary([
                "type": .string("chatgptAuthTokens"),
                "accessToken": .string("token"),
                "chatgptAccountId": .string("account"),
            ])),
            ("amazonBedrock", .dictionary([
                "type": .string("amazonBedrock"),
                "apiKey": .string("bedrock-key"),
                "region": .string("us-east-1"),
                "futureField": .int(7),
            ])),
        ]

        let decoded = try fixtures.map { expectedType, fixture in
            let value = try fixture.decode(CodexSchemaLoginAccountParams.self)
            XCTAssertEqual(value.type, expectedType)
            XCTAssertEqual(value.rawValue, fixture)
            XCTAssertEqual(try CodexJSONValue(encoding: value), fixture)
            return value
        }
        XCTAssertEqual(Set(decoded.map(\.type)), Set(fixtures.map(\.0)))

        for value in decoded {
            switch value {
            case .apiKey, .chatgpt, .chatgptDeviceCode, .chatgptAuthTokens:
                break
            case .amazonBedrock(let payload):
                XCTAssertEqual(payload.region, "us-east-1")
                XCTAssertEqual(payload.unknownFields["futureField"], .int(7))
            case .unrecognized:
                XCTFail("Every pinned alpha.20 login arm must remain generated")
            }
        }

        let future = CodexJSONValue.dictionary([
            "type": .string("futureLogin"),
            "opaque": .bool(true),
        ])
        let unknown = try future.decode(CodexSchemaLoginAccountParams.self)
        guard case .unrecognized(let type, let rawValue) = unknown else {
            return XCTFail("Future login arms must remain lossless")
        }
        XCTAssertEqual(type, "futureLogin")
        XCTAssertEqual(rawValue, future)
    }
}
