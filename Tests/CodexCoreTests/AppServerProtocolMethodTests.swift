import XCTest
@testable import CodexCore

/// Internal consistency checks for the generated protocol surface.
///
/// These tests intentionally avoid hardcoded method counts: counts pinned to a
/// snapshot can only go stale, and comparing `allCases.count` against a
/// constant emitted by the same generator proves nothing. Actual drift against
/// the codex binary is detected by `Tools/check_drift.sh`, which regenerates
/// the files from `codex app-server generate-json-schema --experimental` and
/// diffs them against the committed sources.
final class AppServerProtocolMethodTests: XCTestCase {
    func testGeneratedMethodCountsMatchInventory() {
        XCTAssertEqual(CodexAppServerClientMethod.allCases.count, CodexAppServerProtocolInventory.clientMethodCount)
        XCTAssertEqual(CodexAppServerNotificationMethod.allCases.count, CodexAppServerProtocolInventory.notificationMethodCount)
        XCTAssertEqual(CodexAppServerServerRequestMethod.allCases.count, CodexAppServerProtocolInventory.serverRequestMethodCount)
    }

    func testGeneratedMethodsAreUnique() {
        XCTAssertEqual(Set(CodexAppServerClientMethod.allCases.map(\.rawValue)).count, CodexAppServerClientMethod.allCases.count)
        XCTAssertEqual(Set(CodexAppServerNotificationMethod.allCases.map(\.rawValue)).count, CodexAppServerNotificationMethod.allCases.count)
        XCTAssertEqual(Set(CodexAppServerServerRequestMethod.allCases.map(\.rawValue)).count, CodexAppServerServerRequestMethod.allCases.count)
    }

    /// Every method the SDK invokes through typed wrappers must exist in the
    /// generated enum; removal upstream should fail loudly here.
    func testMethodsUsedByTypedWrappersArePresent() {
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
        XCTAssertTrue(CodexAppServerNotificationMethod.allCases.contains(.serverRequestResolved))

        XCTAssertTrue(CodexAppServerServerRequestMethod.allCases.contains(.itemCommandExecutionRequestApproval))
        XCTAssertTrue(CodexAppServerServerRequestMethod.allCases.contains(.itemToolRequestUserInput))
        XCTAssertTrue(CodexAppServerServerRequestMethod.allCases.contains(.mcpServerElicitationRequest))
        XCTAssertTrue(CodexAppServerServerRequestMethod.allCases.contains(.accountChatGPTAuthTokensRefresh))
    }

    func testCurrentAppProtocolAdditionsArePresent() {
        XCTAssertTrue(CodexAppServerClientMethod.allCases.contains(.accountWorkspaceMessagesRead))
        XCTAssertTrue(CodexAppServerClientMethod.allCases.contains(.externalAgentConfigImportReadHistories))

        XCTAssertTrue(CodexAppServerNotificationMethod.allCases.contains(.externalAgentConfigImportProgress))
        XCTAssertTrue(CodexAppServerNotificationMethod.allCases.contains(.modelSafetyBufferingUpdated))

        XCTAssertTrue(CodexAppServerServerRequestMethod.allCases.contains(.currentTimeRead))

        XCTAssertEqual(
            CodexAppServerSchemaInventory.notificationPayloadByMethod["externalAgentConfig/import/progress"]?.typeName,
            "CodexSchemaExternalAgentConfigImportProgressNotification"
        )
        XCTAssertEqual(
            CodexAppServerSchemaInventory.notificationPayloadByMethod["model/safetyBuffering/updated"]?.typeName,
            "CodexSchemaModelSafetyBufferingUpdatedNotification"
        )
        XCTAssertEqual(
            CodexAppServerSchemaInventory.serverRequestParamByMethod["currentTime/read"]?.definitionName,
            "CurrentTimeReadParams"
        )

        let definitions = Set(CodexAppServerSchemaInventory.definitions.map(\.name))
        XCTAssertTrue(definitions.contains("GetWorkspaceMessagesResponse"))
        XCTAssertTrue(definitions.contains("ExternalAgentConfigImportProgressNotification"))
        XCTAssertTrue(definitions.contains("LegacyAppPathString"))
        XCTAssertTrue(definitions.contains("AmazonBedrockCredentialSource"))
    }

    func testGeneratedSchemaTypeInventoryIsConsistent() {
        XCTAssertEqual(CodexAppServerSchemaInventory.definitions.count, CodexAppServerSchemaInventory.definitionCount)
        XCTAssertEqual(CodexAppServerSchemaInventory.v2SchemaFiles.count, CodexAppServerSchemaInventory.v2SchemaFileCount)
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

    func testGeneratedSchemaTypesAreRealSwiftTypes() throws {
        // Plain object schemas become Codable structs with typed fields.
        let stepData = #"{"step":"Implement fix","status":"inProgress"}"#.data(using: .utf8)!
        let step = try JSONDecoder().decode(CodexSchemaTurnPlanStep.self, from: stepData)
        XCTAssertEqual(step.step, "Implement fix")
        XCTAssertEqual(step.status, .inProgress)

        // CodingKeys map Swift acronym casing back to the wire casing, and
        // unknown wire fields are tolerated.
        let diffData = #"{"threadId":"t1","turnId":"u1","diff":"+1","unknownField":true}"#.data(using: .utf8)!
        let diff = try JSONDecoder().decode(CodexSchemaTurnDiffUpdatedNotification.self, from: diffData)
        XCTAssertEqual(diff.threadID, "t1")
        XCTAssertEqual(diff.turnID, "u1")
        XCTAssertEqual(diff.diff, "+1")

        // Round trip re-encodes with the wire casing.
        let reencoded = try JSONDecoder().decode(
            CodexSchemaTurnDiffUpdatedNotification.self,
            from: JSONEncoder().encode(diff)
        )
        XCTAssertEqual(reencoded, diff)

        // Complex unions stay addressable as raw JSON wrappers.
        let rawData = #"{"method":"thread/start"}"#.data(using: .utf8)!
        let raw = try JSONDecoder().decode(CodexSchemaClientRequest.self, from: rawData)
        XCTAssertEqual(raw.rawValue, .dictionary(["method": .string("thread/start")]))

        // Every definition is exactly one of enum, struct, or raw alias.
        XCTAssertEqual(
            CodexAppServerSchemaInventory.generatedEnumCount
                + CodexAppServerSchemaInventory.generatedStructCount
                + CodexAppServerSchemaInventory.rawAliasCount,
            CodexAppServerSchemaInventory.definitionCount
        )
        XCTAssertGreaterThan(CodexAppServerSchemaInventory.generatedStructCount, 0)
        XCTAssertGreaterThan(CodexAppServerSchemaInventory.generatedEnumCount, 0)
    }

    func testCurrentAppSchemaAdditionsAreRealSwiftTypes() throws {
        let appsConfigData = #"{"approvals_reviewer":"user","default_tools_approval_mode":"approve","enabled":true}"#.data(using: .utf8)!
        let appsConfig = try JSONDecoder().decode(CodexSchemaAppsDefaultConfig.self, from: appsConfigData)
        XCTAssertEqual(appsConfig.defaultToolsApprovalMode, .approve)

        let workspaceMessagesData = #"{"featureEnabled":true,"messages":[{"messageBody":"Hello","messageId":"msg-1","messageType":"headline"}]}"#.data(using: .utf8)!
        let workspaceMessages = try JSONDecoder().decode(CodexSchemaGetWorkspaceMessagesResponse.self, from: workspaceMessagesData)
        XCTAssertTrue(workspaceMessages.featureEnabled)
        XCTAssertEqual(workspaceMessages.messages.first?.messageID, "msg-1")
        XCTAssertEqual(workspaceMessages.messages.first?.messageType, .headline)

        let progressData = #"{"importId":"import-1","itemTypeResults":[{"failures":[],"itemType":"CONFIG","successes":[]}]}"#.data(using: .utf8)!
        let progress = try JSONDecoder().decode(CodexSchemaExternalAgentConfigImportProgressNotification.self, from: progressData)
        XCTAssertEqual(progress.importID, "import-1")
        XCTAssertEqual(progress.itemTypeResults.first?.itemType, .cONFIG)

        let bufferingData = #"{"model":"gpt-5.4","reasons":["safety"],"threadId":"thread-1","turnId":"turn-1","useCases":["chat"]}"#.data(using: .utf8)!
        let buffering = try JSONDecoder().decode(CodexSchemaModelSafetyBufferingUpdatedNotification.self, from: bufferingData)
        XCTAssertEqual(buffering.threadID, "thread-1")
        XCTAssertEqual(buffering.reasons, ["safety"])

        let permissions = CodexSchemaAdditionalFileSystemPermissions(
            read: [CodexAppServerSchemaValue(.string("/tmp/project"))],
            write: [CodexAppServerSchemaValue(.string("/tmp/project/out"))]
        )
        XCTAssertEqual(permissions.read, [CodexAppServerSchemaValue(.string("/tmp/project"))])
        XCTAssertEqual(CodexSchemaAmazonBedrockCredentialSource.allCases, [.codexManaged, .awsManaged])
    }
}
