import XCTest
@testable import CodexCore
@testable import CodexCoreUI

final class CodexManagedPolicyRequirementsTests: XCTestCase {
    func testNoRequirementsPreservesFallbackBehavior() {
        let requirements = CodexManagedPolicyRequirements(requirements: nil)

        XCTAssertFalse(requirements.isManaged)
        XCTAssertEqual(
            CodexApprovalSelection.options(from: [], requirements: requirements),
            CodexApprovalSelection.defaultOptions
        )
        XCTAssertEqual(requirements.narrowSandboxModes(CodexSchemaSandboxMode.allCases), CodexSchemaSandboxMode.allCases)
        XCTAssertEqual(requirements.narrowReviewers(CodexSchemaApprovalsReviewer.allCases), CodexSchemaApprovalsReviewer.allCases)
        XCTAssertEqual(requirements.narrowWebSearchModes(CodexSchemaWebSearchMode.allCases), CodexSchemaWebSearchMode.allCases)
    }

    func testGeneratedRequirementsMapToLockedConstraintsAndNarrowOptions() {
        let generated = CodexSchemaConfigRequirements(
            allowedApprovalPolicies: [CodexSchemaAskForApproval(.string("untrusted"))],
            allowedApprovalsReviewers: [.user],
            allowedPermissionProfiles: [":read-only": true, ":workspace": false],
            allowedSandboxModes: [.readOnly],
            allowedWebSearchModes: [.cached],
            defaultPermissions: ":read-only"
        )
        let requirements = CodexManagedPolicyRequirements(requirements: generated)

        XCTAssertTrue(requirements.isManaged)
        XCTAssertTrue(requirements.isApprovalPolicyAdminLocked)
        XCTAssertTrue(requirements.isSandboxModeAdminLocked)
        XCTAssertTrue(requirements.isReviewerAdminLocked)
        XCTAssertTrue(requirements.isWebSearchModeAdminLocked)
        XCTAssertEqual(requirements.defaultPermissions.value, ":read-only")
        XCTAssertTrue(requirements.defaultPermissions.isAdminLocked)
        XCTAssertEqual(requirements.restrictedCategories.count, 6)

        let profiles = [
            CodexPermissionProfileSummary(id: ":read-only", displayName: "Read only"),
            CodexPermissionProfileSummary(id: ":workspace", displayName: "Workspace"),
            CodexPermissionProfileSummary(id: ":danger-full-access", displayName: "Full access"),
        ]
        XCTAssertEqual(
            CodexApprovalSelection.options(from: profiles, requirements: requirements),
            []
        )
        XCTAssertEqual(
            requirements.defaultApprovalSelection(in: CodexApprovalSelection.defaultOptions),
            nil
        )
        XCTAssertEqual(
            requirements.narrowSandboxModes(CodexSchemaSandboxMode.allCases),
            [.readOnly]
        )
        XCTAssertEqual(
            requirements.narrowReviewers(CodexSchemaApprovalsReviewer.allCases),
            [.user]
        )
        XCTAssertEqual(
            requirements.narrowWebSearchModes(CodexSchemaWebSearchMode.allCases),
            [.cached]
        )
        XCTAssertTrue(requirements.noticeTitle.localizedCaseInsensitiveContains("organization"))
        XCTAssertTrue(requirements.noticeDetail.localizedCaseInsensitiveContains("restricted"))
    }

    func testLegacyGuardianReviewerHydratesAsApproveForMe() {
        let requirements = CodexManagedPolicyRequirements(
            allowedApprovalPolicies: ["on-request"],
            allowedSandboxModes: ["workspace-write"],
            allowedReviewers: ["guardian_subagent"]
        )
        let profiles = [CodexPermissionProfileSummary(id: ":workspace", displayName: "Workspace")]

        XCTAssertEqual(
            CodexApprovalSelection.options(from: profiles, requirements: requirements),
            [.approveForMe]
        )
        XCTAssertEqual(
            CodexApprovalSelection.selection(
                profileID: ":workspace",
                approvalsReviewer: .guardianSubagent
            ),
            .approveForMe
        )
    }

    func testSessionEntryPointReconcilesPolicyWithPermissionCatalog() {
        var session = CodexChatConfigurationSession()
        session.applyConfigurationRequirements(CodexSchemaConfigRequirements(
            allowedApprovalPolicies: [CodexSchemaAskForApproval(.string("untrusted"))],
            allowedApprovalsReviewers: [.user],
            allowedSandboxModes: [.readOnly]
        ))

        XCTAssertTrue(session.approvalOptions.isEmpty)
        XCTAssertEqual(session.approvalSelection, .custom)
        XCTAssertTrue(session.managedPolicyRequirements?.isManaged == true)
    }

    func testAgentInstructionsSettingsRouteIsAvailable() {
        XCTAssertTrue(CodexSettingsRoute.availableRoutes.contains(.agents))
        XCTAssertTrue(CodexSettingsRoute.availableRoutes.contains(.sections))
        XCTAssertTrue(CodexSettingsRoute.availableRoutes.contains(.hooks))
    }
}
