import XCTest
@testable import CodexCore

final class AppServerProtocolMethodTests: XCTestCase {
    func testGeneratedMethodCountsMatchCurrentAppServerSchema() {
        XCTAssertEqual(CodexAppServerClientMethod.allCases.count, CodexAppServerProtocolInventory.clientMethodCount)
        XCTAssertEqual(CodexAppServerNotificationMethod.allCases.count, CodexAppServerProtocolInventory.notificationMethodCount)
        XCTAssertEqual(CodexAppServerServerRequestMethod.allCases.count, CodexAppServerProtocolInventory.serverRequestMethodCount)

        XCTAssertEqual(CodexAppServerClientMethod.allCases.count, 108)
        XCTAssertEqual(CodexAppServerNotificationMethod.allCases.count, 64)
        XCTAssertEqual(CodexAppServerServerRequestMethod.allCases.count, 10)
    }

    func testGeneratedMethodsAreUnique() {
        XCTAssertEqual(Set(CodexAppServerClientMethod.allCases.map(\.rawValue)).count, 108)
        XCTAssertEqual(Set(CodexAppServerNotificationMethod.allCases.map(\.rawValue)).count, 64)
        XCTAssertEqual(Set(CodexAppServerServerRequestMethod.allCases.map(\.rawValue)).count, 10)
    }

    func testCorePythonSDKMethodsArePresent() {
        XCTAssertTrue(CodexAppServerClientMethod.allCases.contains(.initialize))
        XCTAssertTrue(CodexAppServerClientMethod.allCases.contains(.accountLoginStart))
        XCTAssertTrue(CodexAppServerClientMethod.allCases.contains(.threadStart))
        XCTAssertTrue(CodexAppServerClientMethod.allCases.contains(.threadResume))
        XCTAssertTrue(CodexAppServerClientMethod.allCases.contains(.threadFork))
        XCTAssertTrue(CodexAppServerClientMethod.allCases.contains(.threadArchive))
        XCTAssertTrue(CodexAppServerClientMethod.allCases.contains(.turnStart))
        XCTAssertTrue(CodexAppServerClientMethod.allCases.contains(.turnInterrupt))
        XCTAssertTrue(CodexAppServerClientMethod.allCases.contains(.turnSteer))
        XCTAssertTrue(CodexAppServerClientMethod.allCases.contains(.modelList))
        XCTAssertTrue(CodexAppServerClientMethod.allCases.contains(.commandExec))
    }

    func testCoreNotificationAndServerRequestMethodsArePresent() {
        XCTAssertTrue(CodexAppServerNotificationMethod.allCases.contains(.turnStarted))
        XCTAssertTrue(CodexAppServerNotificationMethod.allCases.contains(.turnCompleted))
        XCTAssertTrue(CodexAppServerNotificationMethod.allCases.contains(.itemCompleted))
        XCTAssertTrue(CodexAppServerNotificationMethod.allCases.contains(.accountLoginCompleted))
        XCTAssertTrue(CodexAppServerNotificationMethod.allCases.contains(.commandExecOutputDelta))

        XCTAssertTrue(CodexAppServerServerRequestMethod.allCases.contains(.itemCommandExecutionRequestApproval))
        XCTAssertTrue(CodexAppServerServerRequestMethod.allCases.contains(.itemToolRequestUserInput))
        XCTAssertTrue(CodexAppServerServerRequestMethod.allCases.contains(.mcpServerElicitationRequest))
        XCTAssertTrue(CodexAppServerServerRequestMethod.allCases.contains(.accountChatgptAuthTokensRefresh))
    }

    func testGeneratedSchemaTypeInventoryMatchesCurrentAppServerSchema() {
        XCTAssertEqual(CodexAppServerSchemaInventory.definitionCount, 510)
        XCTAssertEqual(CodexAppServerSchemaInventory.v2SchemaFileCount, 259)
        XCTAssertEqual(CodexAppServerSchemaInventory.definitions.count, CodexAppServerSchemaInventory.definitionCount)
        XCTAssertEqual(CodexAppServerSchemaInventory.v2SchemaFiles.count, CodexAppServerSchemaInventory.v2SchemaFileCount)
        XCTAssertEqual(CodexAppServerSchemaInventory.clientRequestParamCount, 99)
        XCTAssertEqual(CodexAppServerSchemaInventory.notificationPayloadCount, CodexAppServerProtocolInventory.notificationMethodCount)
        XCTAssertEqual(CodexAppServerSchemaInventory.serverRequestParamCount, CodexAppServerProtocolInventory.serverRequestMethodCount)
        XCTAssertEqual(CodexAppServerSchemaInventory.clientRequestParams.count, CodexAppServerSchemaInventory.clientRequestParamCount)
        XCTAssertEqual(CodexAppServerSchemaInventory.notificationPayloads.count, CodexAppServerSchemaInventory.notificationPayloadCount)
        XCTAssertEqual(CodexAppServerSchemaInventory.serverRequestParams.count, CodexAppServerSchemaInventory.serverRequestParamCount)
        XCTAssertEqual(Set(CodexAppServerSchemaInventory.definitions.map(\.name)).count, CodexAppServerSchemaInventory.definitionCount)
        XCTAssertEqual(Set(CodexAppServerSchemaInventory.definitions.map(\.typeName)).count, CodexAppServerSchemaInventory.definitionCount)

        for method in CodexAppServerNotificationMethod.allCases {
            let schema = method.schemaDefinition
            XCTAssertNotNil(schema, "Missing notification schema for \(method.rawValue)")
            XCTAssertEqual(schema?.method, method.rawValue)
            XCTAssertFalse(schema?.definitionName.isEmpty ?? true)
            XCTAssertFalse(schema?.typeName.isEmpty ?? true)
        }

        for method in CodexAppServerServerRequestMethod.allCases {
            let schema = method.paramsSchemaDefinition
            XCTAssertNotNil(schema, "Missing server request params schema for \(method.rawValue)")
            XCTAssertEqual(schema?.method, method.rawValue)
            XCTAssertFalse(schema?.definitionName.isEmpty ?? true)
        }

        let names = Set(CodexAppServerSchemaInventory.definitions.map(\.name))
        XCTAssertTrue(names.contains("Thread"))
        XCTAssertTrue(names.contains("Turn"))
        XCTAssertTrue(names.contains("LoginAccountParams"))
        XCTAssertTrue(names.contains("ThreadStartParams"))
        XCTAssertTrue(names.contains("AccountLoginCompletedNotification"))
    }

    func testGeneratedSchemaAliasesDecodeRawJSON() throws {
        let data = #"{"id":"thread-1","status":{"type":"active"}}"#.data(using: .utf8)!
        let thread = try JSONDecoder().decode(CodexSchemaThread.self, from: data)
        XCTAssertEqual(thread.rawValue, .dictionary([
            "id": .string("thread-1"),
            "status": .dictionary(["type": .string("active")])
        ]))

        let response = CodexSchemaTurnStartResponse(.dictionary([
            "turn": .dictionary(["id": .string("turn-1")])
        ]))
        let encoded = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(CodexSchemaTurnStartResponse.self, from: encoded)
        XCTAssertEqual(decoded.rawValue, response.rawValue)
    }
}
