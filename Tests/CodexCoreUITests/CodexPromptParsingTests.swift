import XCTest
@testable import CodexCore
@testable import CodexCoreUI

/// Non-request configuration parsing retained here. Raw server-request prompt
/// parsing was removed with the legacy Connection/Store prompt path; typed
/// inbox projection is covered by `CodexPromptStateSessionTests`.
final class CodexPromptParsingTests: XCTestCase {
    func testPermissionProfilesParseAppServerAccessOptions() throws {
        let raw = CodexJSONValue.dictionary([
            "data": .array([
                .dictionary(["id": .string(":read-only"), "description": .null]),
                .dictionary(["id": .string(":workspace"), "description": .null]),
                .dictionary(["id": .string(":danger-full-access"), "description": .null]),
            ]),
            "nextCursor": .null,
        ])

        let profiles = CodexPermissionProfileSummary.profiles(from: raw)
        XCTAssertEqual(profiles.map(\.id), [":read-only", ":workspace", ":danger-full-access"])
        XCTAssertEqual(profiles.map(\.displayName), ["Read only", "Workspace", "Full access"])
        XCTAssertEqual(
            CodexApprovalSelection.options(from: profiles),
            [.readOnly, .askForApproval, .approveForMe, .fullAccess, .custom]
        )
        XCTAssertEqual(
            CodexApprovalSelection.options(from: []),
            CodexApprovalSelection.defaultOptions
        )
    }

    func testCollaborationModesParseAppServerPlanModeOptions() throws {
        let raw = CodexJSONValue.dictionary([
            "data": .array([
                .dictionary([
                    "name": .string("Plan"),
                    "mode": .string("plan"),
                    "model": .null,
                    "reasoning_effort": .string("medium"),
                ]),
                .dictionary([
                    "name": .string("Default"),
                    "mode": .string("default"),
                    "model": .null,
                    "reasoning_effort": .null,
                ]),
            ])
        ])

        let modes = CodexCollaborationModeOption.options(from: raw)
        XCTAssertEqual(modes.map(\.name), ["Plan", "Default"])
        XCTAssertEqual(modes.map(\.mode), ["plan", "default"])
        XCTAssertEqual(modes.first?.reasoning, .medium)
        XCTAssertTrue(modes.first?.isPlanMode == true)
        XCTAssertFalse(modes.last?.isPlanMode == true)
    }
}
