import XCTest
@testable import CodexCore
@testable import CodexCoreUI

final class CodexPermissionProfileWireTests: XCTestCase {
    func testBuiltInSelectionsResolveExactProfilesAndOnlyRequiredLegacyOverrides() {
        assertWireConfiguration(
            .readOnly,
            permissions: ":read-only",
            approvalPolicy: "untrusted",
            approvalsReviewer: "user"
        )
        assertWireConfiguration(
            .askForApproval,
            permissions: ":workspace",
            approvalPolicy: "on-request",
            approvalsReviewer: "user"
        )
        assertWireConfiguration(
            .approveForMe,
            permissions: ":workspace",
            approvalPolicy: "on-request",
            approvalsReviewer: "auto_review"
        )
        assertWireConfiguration(
            .guardianSubagent,
            permissions: ":workspace",
            approvalPolicy: "on-request",
            approvalsReviewer: "guardian_subagent"
        )
        assertWireConfiguration(
            .fullAccess,
            permissions: ":danger-full-access",
            approvalPolicy: "never",
            approvalsReviewer: "user"
        )
        assertWireConfiguration(.custom, permissions: nil)
    }

    func testEveryBuiltInProfileEncodesOnMutationPathsAndClearsDerivedSandbox() throws {
        let expectations: [
            (
                selection: CodexApprovalSelection,
                policy: String,
                reviewer: String
            )
        ] = [
            (.readOnly, "untrusted", "user"),
            (.askForApproval, "on-request", "user"),
            (.approveForMe, "on-request", "auto_review"),
            (.guardianSubagent, "on-request", "guardian_subagent"),
            (.fullAccess, "never", "user"),
        ]
        for expectation in expectations {
            let configuration = expectation.selection.permissionProfileWireConfiguration

            var start = CodexSchemaThreadStartParams(
                approvalPolicy: CodexSchemaAskForApproval(.string("never")),
                approvalsReviewer: CodexSchemaApprovalsReviewer(rawValue: "auto_review"),
                sandbox: CodexSchemaSandboxMode(rawValue: "danger-full-access")
            )
            configuration.apply(to: &start)
            try assertEncodedWireFields(
                start,
                permissions: expectation.selection.permissionProfileID,
                approvalPolicy: expectation.policy,
                approvalsReviewer: expectation.reviewer
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
                permissions: expectation.selection.permissionProfileID,
                approvalPolicy: expectation.policy,
                approvalsReviewer: expectation.reviewer
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
                permissions: expectation.selection.permissionProfileID,
                approvalPolicy: expectation.policy,
                approvalsReviewer: expectation.reviewer
            )
        }
    }

    func testCustomOmitsProfileAndAllLegacyPermissionOverridesOnMutationPaths() throws {
        let configuration = CodexApprovalSelection.custom.permissionProfileWireConfiguration

        var start = CodexSchemaThreadStartParams(
            approvalPolicy: CodexSchemaAskForApproval(.string("on-request")),
            approvalsReviewer: CodexSchemaApprovalsReviewer(rawValue: "user"),
            permissions: ":workspace",
            sandbox: CodexSchemaSandboxMode(rawValue: "workspace-write")
        )
        configuration.apply(to: &start)
        try assertEncodedWireFields(start, permissions: nil)

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

    func testResumeLeavesPermissionFieldsUnsetForServerStateHydration() throws {
        let resume = CodexSchemaThreadResumeParams(
            cwd: "/tmp/project",
            threadID: "thread"
        )

        try assertEncodedWireFields(resume, permissions: nil)
    }

    func testActiveExplicitProfileHydratesSelectionAndDisablesCustomUntilThreadClears() {
        var session = CodexChatConfigurationSession(approvalSelection: .custom)
        _ = session.applyPermissionProfileResponse(.dictionary([
            "data": .array([
                profile(":read-only"),
                profile(":workspace"),
                profile(":danger-full-access"),
            ])
        ]))

        session.applyActiveThreadPermissionConfiguration(.init(
            profileID: ":workspace",
            approvalPolicy: CodexSchemaAskForApproval(.string("on-request")),
            approvalsReviewer: .autoReview
        ))

        XCTAssertEqual(session.approvalSelection, .approveForMe)
        XCTAssertFalse(session.approvalOptions.contains(.custom))

        session.clearActiveThreadPermissionConfiguration()
        XCTAssertTrue(session.approvalOptions.contains(.custom))

        session.applyActiveThreadPermissionConfiguration(.init(
            profileID: nil,
            approvalPolicy: CodexSchemaAskForApproval(.string("on-request")),
            approvalsReviewer: .user
        ))
        XCTAssertEqual(session.approvalSelection, .custom)
        XCTAssertTrue(session.approvalOptions.contains(.custom))
    }

    func testUnknownActiveProfileCannotLeakThePreviousThreadSelection() {
        var session = CodexChatConfigurationSession(
            approvalSelection: .fullAccess
        )

        session.applyActiveThreadPermissionConfiguration(.init(
            profileID: "managed-team-profile",
            approvalPolicy: CodexSchemaAskForApproval(.string("on-request")),
            approvalsReviewer: .user
        ))

        XCTAssertEqual(session.approvalSelection, .custom)
        XCTAssertFalse(session.approvalOptions.contains(.custom))

        session.clearActiveThreadPermissionConfiguration()
        XCTAssertTrue(session.approvalOptions.contains(.custom))
    }

    func testHydratedFullAccessDoesNotBecomeMainOrVoiceNewThreadAmbientSelection() throws {
        var session = CodexChatConfigurationSession(
            approvalSelection: .askForApproval
        )
        session.applyActiveThreadPermissionConfiguration(.init(
            profileID: ":danger-full-access",
            approvalPolicy: CodexSchemaAskForApproval(.string("never")),
            approvalsReviewer: .user
        ))

        XCTAssertEqual(session.approvalSelection, .fullAccess)
        XCTAssertEqual(session.newThreadApprovalSelection, .askForApproval)

        var voiceStart = CodexSchemaThreadStartParams()
        session.newThreadApprovalSelection.permissionProfileWireConfiguration
            .apply(to: &voiceStart)
        try assertEncodedWireFields(
            voiceStart,
            permissions: ":workspace",
            approvalPolicy: "on-request",
            approvalsReviewer: "user"
        )

        session.clearActiveThreadPermissionConfiguration()
        XCTAssertEqual(session.approvalSelection, .askForApproval)

        var mainStart = CodexSchemaThreadStartParams()
        session.newThreadApprovalSelection.permissionProfileWireConfiguration
            .apply(to: &mainStart)
        try assertEncodedWireFields(
            mainStart,
            permissions: ":workspace",
            approvalPolicy: "on-request",
            approvalsReviewer: "user"
        )
    }

    func testPreparingTurnOrForkTransitionIsSideEffectFreeUntilSuccess() {
        var session = CodexChatConfigurationSession(
            approvalSelection: .custom
        )
        session.applyActiveThreadPermissionConfiguration(.init(
            profileID: nil,
            approvalPolicy: CodexSchemaAskForApproval(.string("on-request")),
            approvalsReviewer: .user
        ))
        let configuration =
            CodexApprovalSelection.askForApproval.permissionProfileWireConfiguration

        var turn = CodexSchemaTurnStartParams(input: [], threadID: "thread")
        configuration.apply(to: &turn)
        var fork = CodexSchemaThreadForkParams(threadID: "thread")
        configuration.apply(to: &fork)

        // Parameter construction is the only state reached by a failed RPC,
        // and a fork transition belongs to its response rather than its source.
        XCTAssertEqual(session.approvalSelection, .custom)
        XCTAssertTrue(session.approvalOptions.contains(.custom))

        // A successful main turn commits the exact configuration it sent.
        session.markPermissionProfileActive(configuration)
        XCTAssertEqual(session.approvalSelection, .askForApproval)
        XCTAssertFalse(session.approvalOptions.contains(.custom))
    }

    func testExplicitActiveProfileKeepsEmptyAllowedOptionsEmpty() {
        var session = CodexChatConfigurationSession()
        _ = session.applyPermissionProfileResponse(.dictionary([
            "data": .array([
                profile(":workspace", allowed: false),
            ])
        ]))
        XCTAssertEqual(session.approvalOptions, [.custom])

        session.applyActiveThreadPermissionConfiguration(.init(
            profileID: ":workspace",
            approvalPolicy: CodexSchemaAskForApproval(.string("on-request")),
            approvalsReviewer: .user
        ))

        XCTAssertEqual(session.approvalSelection, .askForApproval)
        XCTAssertTrue(session.approvalOptions.isEmpty)

        _ = session.failPermissionProfileRefresh(message: "offline")
        XCTAssertTrue(session.approvalOptions.isEmpty)
    }

    func testFullAccessSelectionRequiresConfirmationFromEitherSelector() {
        XCTAssertEqual(
            CodexPermissionSelectionDecision.resolve(
                current: .approveForMe,
                requested: .fullAccess
            ),
            .confirmFullAccess
        )
        XCTAssertEqual(
            CodexPermissionSelectionDecision.resolve(
                current: .fullAccess,
                requested: .fullAccess
            ),
            .apply(.fullAccess)
        )
        XCTAssertEqual(
            CodexPermissionSelectionDecision.resolve(
                current: .fullAccess,
                requested: .readOnly
            ),
            .apply(.readOnly)
        )
    }

    func testDefaultResetAndCatalogFallbackNeverElevateToFullAccess() {
        var session = CodexChatConfigurationSession()
        XCTAssertEqual(session.approvalSelection, .askForApproval)
        XCTAssertNotEqual(
            session.approvalSelection.permissionProfileID,
            ":danger-full-access"
        )

        session.approvalSelection = .fullAccess
        session.reset()
        XCTAssertEqual(session.approvalSelection, .askForApproval)

        _ = session.applyPermissionProfileResponse(.dictionary([
            "data": .array([
                profile(":danger-full-access"),
            ])
        ]))
        XCTAssertEqual(session.approvalSelection, .custom)
        XCTAssertNotEqual(
            session.approvalSelection.permissionProfileID,
            ":danger-full-access"
        )
    }

    private func profile(_ id: String, allowed: Bool = true) -> CodexJSONValue {
        .dictionary([
            "id": .string(id),
            "allowed": .bool(allowed),
            "description": .null,
        ])
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
