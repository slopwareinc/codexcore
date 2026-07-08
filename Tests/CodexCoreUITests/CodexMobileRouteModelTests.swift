import XCTest
@testable import CodexCore
@testable import CodexCoreUI

final class CodexMobileRouteModelTests: XCTestCase {
    func testMobileRouteCopyAndGetStartedOpensPermissionGateWithoutEnabling() {
        var session = CodexMobileRouteSession()

        let activity = session.getStarted()

        XCTAssertEqual(activity.title, "Codex Mobile")
        XCTAssertTrue(session.state.isPermissionGatePresented)
        XCTAssertEqual(session.state.title, "Connect your phone to this Mac")
        XCTAssertEqual(session.state.subtitle, "Keep working from your phone, or other device")
        XCTAssertEqual(session.state.benefits, ["Pick up where you left off", "Stay in the loop", "Start something new"])
        XCTAssertEqual(session.state.permissionTitle, "Set up Codex Mobile")
        XCTAssertEqual(session.state.permissionQuestion, "Allow devices to control this computer?")
        XCTAssertEqual(session.state.status.kind, .disabled)
    }

    func testRemoteControlStatusParsesDisabledEnabledAndErrorStates() async {
        let disabled = CodexRemoteControlStatusModel(response: CodexSchemaRemoteControlStatusReadResponse(
            installationID: "install-1",
            serverName: "Codex",
            status: .disabled
        ))
        let enabled = CodexRemoteControlStatusModel(response: CodexSchemaRemoteControlStatusReadResponse(
            environmentID: "env-1",
            installationID: "install-1",
            serverName: "Codex",
            status: .connected
        ))
        var session = CodexMobileRouteSession()
        let error = await session.refreshStatus(provider: MockRemoteControlProvider(errorMessage: "auth required"))

        XCTAssertEqual(disabled.kind, .disabled)
        XCTAssertEqual(disabled.statusLine, "Disabled")
        XCTAssertEqual(enabled.kind, .enabled)
        XCTAssertEqual(enabled.environmentID, "env-1")
        XCTAssertEqual(error.title, "Remote control unavailable")
        XCTAssertEqual(session.state.status.kind, .error)
        XCTAssertEqual(session.state.status.statusLine, "auth required")
    }

    func testAllowUsesProviderAfterPermissionConfirmationAndLoadsPairingAndClients() async {
        var session = CodexMobileRouteSession()
        _ = session.getStarted()

        let activity = await session.allow(provider: MockRemoteControlProvider())

        XCTAssertFalse(session.state.isPermissionGatePresented)
        XCTAssertEqual(activity.title, "Codex Mobile enabled")
        XCTAssertEqual(session.state.status.kind, .enabled)
        XCTAssertEqual(session.state.status.environmentID, "env-1")
        XCTAssertEqual(session.state.pairing.state, .pending)
        XCTAssertEqual(session.state.pairing.pairingCode, "pair-123")
        XCTAssertEqual(session.state.pairing.manualPairingCode, "MANUAL-123")
        XCTAssertEqual(session.state.clients.map(\.displayName), ["Ari's iPhone"])
    }

    func testPairingStatusModelTracksPendingAndClaimedStates() {
        var pairing = CodexRemoteControlPairingModel(start: CodexSchemaRemoteControlPairingStartResponse(
            environmentID: "env-1",
            expiresAt: 1_782_400_000,
            manualPairingCode: "MANUAL-123",
            pairingCode: "pair-123"
        ))

        XCTAssertEqual(pairing.state, .pending)
        XCTAssertEqual(pairing.statusLabel, "Pairing pending")

        pairing.apply(status: CodexSchemaRemoteControlPairingStatusResponse(claimed: true))

        XCTAssertEqual(pairing.state, .claimed)
        XCTAssertEqual(pairing.statusLabel, "Paired")
    }

    func testAboutMetadataFormatsFilledAndFallbackVersionLines() {
        let filled = CodexAboutMetadata(
            appName: "Codex",
            version: "26.616.81150",
            build: "616",
            releaseDate: "Jun 24, 2026",
            copyright: "© OpenAI",
            serverName: "codex-cli 0.142.0"
        )
        let fallback = CodexAboutMetadata(appName: "Codex")

        XCTAssertEqual(filled.versionLine, "Version 26.616.81150 • Build 616 • Released Jun 24, 2026")
        XCTAssertEqual(filled.serverName, "codex-cli 0.142.0")
        XCTAssertEqual(fallback.versionLine, "Version unavailable • Release date unavailable")
    }
}

private struct MockRemoteControlProvider: CodexRemoteControlProvider {
    var errorMessage: String?

    func readStatus() async throws -> CodexRemoteControlStatusModel {
        if let errorMessage {
            throw CodexRemoteControlBoundaryError(errorMessage)
        }
        return CodexRemoteControlStatusModel(kind: .enabled, serverName: "Codex", installationID: "install-1", environmentID: "env-1")
    }

    func enable() async throws -> CodexRemoteControlStatusModel {
        CodexRemoteControlStatusModel(kind: .enabled, serverName: "Codex", installationID: "install-1", environmentID: "env-1")
    }

    func startPairing() async throws -> CodexRemoteControlPairingModel {
        CodexRemoteControlPairingModel(start: CodexSchemaRemoteControlPairingStartResponse(
            environmentID: "env-1",
            expiresAt: 1_782_400_000,
            manualPairingCode: "MANUAL-123",
            pairingCode: "pair-123"
        ))
    }

    func readPairingStatus(pairingCode: String?, manualPairingCode: String?) async throws -> Bool {
        true
    }

    func listClients(environmentID: String) async throws -> [CodexRemoteControlClientSummary] {
        [
            CodexRemoteControlClientSummary(client: CodexSchemaRemoteControlClient(
                appVersion: "1.0",
                clientID: "client-1",
                deviceModel: "iPhone",
                displayName: "Ari's iPhone",
                lastSeenAt: 1_782_300_000,
                osVersion: "iOS 26",
                platform: "iOS"
            ))
        ]
    }

    func revokeClient(clientID: String, environmentID: String) async throws {}
}
