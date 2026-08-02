import XCTest
@testable import CodexCore
@testable import CodexCoreUI

final class CodexIntegrationControlPlaneTests: XCTestCase {
    func testRequestsExposeStableMethodSurfaceAndPermissionBoundaries() {
        let oauth = CodexIntegrationControlPlaneRequest.mcpOAuthLogin(.init(name: "github"))
        XCTAssertEqual(oauth.operationID, "mcpServer/oauth/login")
        XCTAssertEqual(oauth.surface, .mcp)
        XCTAssertEqual(oauth.permissionBoundary, .externalAuthentication)

        let apps = CodexIntegrationControlPlaneRequest.appInstalled(.init(threadID: "thread-1"))
        XCTAssertEqual(apps.operationID, "app/installed")
        XCTAssertEqual(apps.surface, .apps)
        XCTAssertNil(apps.permissionBoundary)

        let hooks = CodexIntegrationControlPlaneRequest.hooksList(.init(cwds: ["/tmp/project"]))
        XCTAssertEqual(hooks.operationID, "hooks/list")
        XCTAssertEqual(hooks.surface, .hooks)
        XCTAssertNil(hooks.permissionBoundary)

        let write = CodexIntegrationControlPlaneRequest.skillsExtraRootsSet(.init(
            extraRoots: [CodexSchemaAbsolutePathBuf(.string("/tmp/skills"))]
        ))
        XCTAssertEqual(write.permissionBoundary, .skillConfigurationWrite)
    }

    func testSessionStoresDistinctResponsesForOperationsOnSameSurface() async {
        let provider = MockIntegrationControlPlaneProvider { request in
            .dictionary(["operation": .string(request.operationID)])
        }
        let list = CodexIntegrationControlPlaneRequest.appList(.init(limit: 10))
        let installed = CodexIntegrationControlPlaneRequest.appInstalled(.init())
        var session = CodexIntegrationControlPlaneSession()

        _ = await session.perform(list, provider: provider) { $0.localizedDescription }
        _ = await session.perform(installed, provider: provider) { $0.localizedDescription }

        XCTAssertEqual(session.phase(for: .apps), .loaded)
        XCTAssertEqual(session.response(for: list), .dictionary(["operation": .string("app/list")]))
        XCTAssertEqual(session.response(for: installed), .dictionary(["operation": .string("app/installed")]))
    }

    func testSessionSurfacesErrorsAndExplicitPermissionBoundary() async {
        var session = CodexIntegrationControlPlaneSession()
        session.requirePermission(
            .externalToolExecution,
            for: .mcp,
            message: "Confirm external tool call"
        )
        XCTAssertEqual(
            session.phase(for: .mcp),
            .permissionRequired(.externalToolExecution, message: "Confirm external tool call")
        )

        let request = CodexIntegrationControlPlaneRequest.pluginShareList(.init())
        let activity = await session.perform(
            request,
            provider: MockIntegrationControlPlaneProvider { _ in
                throw CodexIntegrationControlPlaneError("sharing disabled")
            },
            errorMessage: { $0.localizedDescription }
        )

        XCTAssertEqual(session.phase(for: .plugins), .failed("sharing disabled"))
        XCTAssertEqual(activity.title, "Plugins unavailable")
        XCTAssertEqual(activity.detail, "sharing disabled")
    }

    func testPluginActionAdapterRoutesMutationsAndRefreshesOnlyOnSuccess() async {
        let recorder = IntegrationRequestRecorder()
        let provider = MockIntegrationControlPlaneProvider { request in
            await recorder.record(request)
            return .dictionary([:])
        }
        let actions = CodexAppServerPluginCatalogActionProvider(provider: provider)
        let target = CodexPluginActionTarget(plugin: CodexPluginSummary(
            id: "local:github",
            name: "github",
            displayName: "GitHub",
            marketplaceName: "local",
            marketplacePath: "/tmp/marketplace.json",
            installed: false,
            enabled: false
        ))

        let install = await actions.installPlugin(target)
        let toggle = await actions.setPluginEnabled(target, enabled: true)

        XCTAssertTrue(install.shouldRefresh)
        XCTAssertTrue(toggle.shouldRefresh)
        let requests = await recorder.requests
        XCTAssertEqual(requests.map(\.operationID), ["plugin/install", "config/value/write"])
        XCTAssertEqual(requests.map(\.permissionBoundary), [.pluginMutation, .configurationWrite])
    }
}

private struct MockIntegrationControlPlaneProvider: CodexIntegrationControlPlaneProvider {
    let handler: @Sendable (CodexIntegrationControlPlaneRequest) async throws -> CodexJSONValue

    init(handler: @escaping @Sendable (CodexIntegrationControlPlaneRequest) async throws -> CodexJSONValue) {
        self.handler = handler
    }

    func perform(_ request: CodexIntegrationControlPlaneRequest) async throws -> CodexJSONValue {
        try await handler(request)
    }
}

private actor IntegrationRequestRecorder {
    private(set) var requests: [CodexIntegrationControlPlaneRequest] = []

    func record(_ request: CodexIntegrationControlPlaneRequest) {
        requests.append(request)
    }
}
