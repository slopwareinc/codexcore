import XCTest
@testable import CodexCore
@testable import CodexCoreUI

final class CodexPermissionProfileWireTests: XCTestCase {
    func testBuiltInSelectionsResolveExactProfilesAndOnlyRequiredLegacyOverrides() {
        assertWireConfiguration(.readOnly, permissions: ":read-only")
        assertWireConfiguration(
            .askForApproval,
            permissions: ":workspace",
            approvalPolicy: "on-request",
            approvalsReviewer: "user"
        )
        assertWireConfiguration(.approveForMe, permissions: ":workspace")
        assertWireConfiguration(.fullAccess, permissions: ":danger-full-access")
        assertWireConfiguration(.custom, permissions: nil)
    }

    func testEveryBuiltInProfileEncodesOnEveryRequestPathAndClearsDerivedSandbox() throws {
        for selection in [
            CodexApprovalSelection.readOnly,
            .askForApproval,
            .approveForMe,
            .fullAccess,
        ] {
            let configuration = selection.permissionProfileWireConfiguration
            let expectedPolicy = selection == .askForApproval ? "on-request" : nil
            let expectedReviewer = selection == .askForApproval ? "user" : nil

            var start = CodexSchemaThreadStartParams(
                approvalPolicy: CodexSchemaAskForApproval(.string("never")),
                approvalsReviewer: CodexSchemaApprovalsReviewer(rawValue: "auto_review"),
                sandbox: CodexSchemaSandboxMode(rawValue: "danger-full-access")
            )
            configuration.apply(to: &start)
            try assertEncodedWireFields(
                start,
                permissions: selection.permissionProfileID,
                approvalPolicy: expectedPolicy,
                approvalsReviewer: expectedReviewer
            )

            var resume = CodexSchemaThreadResumeParams(
                approvalPolicy: CodexSchemaAskForApproval(.string("never")),
                approvalsReviewer: CodexSchemaApprovalsReviewer(rawValue: "auto_review"),
                sandbox: CodexSchemaSandboxMode(rawValue: "danger-full-access"),
                threadID: "thread"
            )
            configuration.apply(to: &resume)
            try assertEncodedWireFields(
                resume,
                permissions: selection.permissionProfileID,
                approvalPolicy: expectedPolicy,
                approvalsReviewer: expectedReviewer
            )

            var fork = CodexSchemaThreadForkParams(
                approvalPolicy: CodexSchemaAskForApproval(.string("never")),
                approvalsReviewer: CodexSchemaApprovalsReviewer(rawValue: "auto_review"),
                sandbox: CodexSchemaSandboxMode(rawValue: "danger-full-access"),
                threadID: "thread"
            )
            configuration.apply(to: &fork)
            try assertEncodedWireFields(
                fork,
                permissions: selection.permissionProfileID,
                approvalPolicy: expectedPolicy,
                approvalsReviewer: expectedReviewer
            )

            var turn = CodexSchemaTurnStartParams(
                approvalPolicy: CodexSchemaAskForApproval(.string("never")),
                approvalsReviewer: CodexSchemaApprovalsReviewer(rawValue: "auto_review"),
                input: [],
                sandboxPolicy: CodexSchemaSandboxPolicy(
                    .dictionary(["type": .string("dangerFullAccess")])
                ),
                threadID: "thread"
            )
            configuration.apply(to: &turn)
            try assertEncodedWireFields(
                turn,
                permissions: selection.permissionProfileID,
                approvalPolicy: expectedPolicy,
                approvalsReviewer: expectedReviewer
            )
        }
    }

    func testCustomOmitsProfileAndAllLegacyPermissionOverridesOnEveryRequestPath() throws {
        let configuration = CodexApprovalSelection.custom.permissionProfileWireConfiguration

        var start = CodexSchemaThreadStartParams(
            approvalPolicy: CodexSchemaAskForApproval(.string("on-request")),
            approvalsReviewer: CodexSchemaApprovalsReviewer(rawValue: "user"),
            permissions: ":workspace",
            sandbox: CodexSchemaSandboxMode(rawValue: "workspace-write")
        )
        configuration.apply(to: &start)
        try assertEncodedWireFields(start, permissions: nil)

        var resume = CodexSchemaThreadResumeParams(
            approvalPolicy: CodexSchemaAskForApproval(.string("on-request")),
            approvalsReviewer: CodexSchemaApprovalsReviewer(rawValue: "user"),
            permissions: ":workspace",
            sandbox: CodexSchemaSandboxMode(rawValue: "workspace-write"),
            threadID: "thread"
        )
        configuration.apply(to: &resume)
        try assertEncodedWireFields(resume, permissions: nil)

        var fork = CodexSchemaThreadForkParams(
            approvalPolicy: CodexSchemaAskForApproval(.string("on-request")),
            approvalsReviewer: CodexSchemaApprovalsReviewer(rawValue: "user"),
            permissions: ":workspace",
            sandbox: CodexSchemaSandboxMode(rawValue: "workspace-write"),
            threadID: "thread"
        )
        configuration.apply(to: &fork)
        try assertEncodedWireFields(fork, permissions: nil)

        var turn = CodexSchemaTurnStartParams(
            approvalPolicy: CodexSchemaAskForApproval(.string("on-request")),
            approvalsReviewer: CodexSchemaApprovalsReviewer(rawValue: "user"),
            input: [],
            permissions: ":workspace",
            sandboxPolicy: CodexSchemaSandboxPolicy(
                .dictionary(["type": .string("workspaceWrite")])
            ),
            threadID: "thread"
        )
        configuration.apply(to: &turn)
        try assertEncodedWireFields(turn, permissions: nil)
    }

    private func assertWireConfiguration(
        _ selection: CodexApprovalSelection,
        permissions: String?,
        approvalPolicy: String? = nil,
        approvalsReviewer: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let configuration = selection.permissionProfileWireConfiguration
        XCTAssertEqual(configuration.permissions, permissions, file: file, line: line)
        XCTAssertEqual(configuration.approvalPolicy?.rawValue.stringValue, approvalPolicy, file: file, line: line)
        XCTAssertEqual(configuration.approvalsReviewer?.rawValue, approvalsReviewer, file: file, line: line)
    }

    private func assertEncodedWireFields<T: Encodable>(
        _ parameters: T,
        permissions: String?,
        approvalPolicy: String? = nil,
        approvalsReviewer: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let encoded = try CodexJSONValue(encoding: parameters)
        guard case .dictionary(let object) = encoded else {
            return XCTFail("Expected encoded request object", file: file, line: line)
        }
        XCTAssertEqual(object["permissions"]?.stringValue, permissions, file: file, line: line)
        XCTAssertEqual(object["approvalPolicy"]?.stringValue, approvalPolicy, file: file, line: line)
        XCTAssertEqual(object["approvalsReviewer"]?.stringValue, approvalsReviewer, file: file, line: line)
        XCTAssertNil(object["sandbox"], file: file, line: line)
        XCTAssertNil(object["sandboxPolicy"], file: file, line: line)
    }
}

private extension CodexJSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}
