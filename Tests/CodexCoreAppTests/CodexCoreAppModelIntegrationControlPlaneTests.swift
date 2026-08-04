import XCTest
@testable import CodexCoreUI
@testable import CodexCoreApp

final class CodexCoreAppModelIntegrationControlPlaneTests: XCTestCase {
    @MainActor
    func testDisconnectedHostRequestPublishesExplicitSurfaceError() async {
        let model = CodexCoreAppModel()
        let request = CodexIntegrationControlPlaneRequest.appInstalled(.init())

        let response = await model.performIntegrationControlPlaneRequest(request)

        XCTAssertNil(response)
        XCTAssertEqual(
            model.runtimeSession.integrationControlPlaneSession.phase(for: .apps),
            .failed("Connect to Codex before using apps.")
        )
    }
}
