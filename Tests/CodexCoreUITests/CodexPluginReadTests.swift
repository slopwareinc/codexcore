import XCTest
@testable import CodexCore
@testable import CodexCoreUI

final class CodexPluginReadTests: XCTestCase {
    func testReadUsesMarketplaceIdentityAndMapsAuthoritativeRelationships() {
        let plugin = CodexPluginSummary(
            id: "official:github",
            name: "github",
            marketplaceName: "official",
            marketplacePath: "/registered/official/marketplace.json",
            installed: true,
            enabled: true
        )
        XCTAssertEqual(
            CodexPluginProtocolMutation.readParams(for: plugin),
            CodexSchemaPluginReadParams(
                marketplacePath: CodexAppServerSchemaValue(.string("/registered/official/marketplace.json")),
                pluginName: "github"
            )
        )

        let summary = CodexSchemaPluginSummary(
            authPolicy: .oNUSE,
            enabled: true,
            id: "github",
            installPolicy: .aVAILABLE,
            installed: true,
            name: "github",
            source: CodexAppServerSchemaValue(.dictionary(["type": .string("local")]))
        )
        let detail = CodexSchemaPluginDetail(
            appTemplates: [
                .init(materializedAppIDs: [], name: "GitHub template", templateID: "github-template")
            ],
            apps: [
                .init(id: "github-app", name: "GitHub App")
            ],
            description: "Authoritative plugin detail",
            hooks: [
                .init(eventName: .sessionStart, key: "prepare")
            ],
            marketplaceName: "official",
            marketplacePath: CodexAppServerSchemaValue(.string("/registered/official/marketplace.json")),
            mcpServers: ["github-mcp"],
            shareUrl: "https://example.test/share/github",
            skills: [
                .init(description: "Triage issues", enabled: true, name: "github:triage")
            ],
            summary: summary
        )

        var session = CodexIntegrationCatalogSession()
        session.beginPluginRead(id: plugin.id)
        XCTAssertEqual(session.loadingPluginReadIDs, [plugin.id])
        session.applyPluginRead(id: plugin.id, response: .init(plugin: detail))

        XCTAssertEqual(session.pluginReadDetails[plugin.id], CodexPluginReadDetail(id: plugin.id, detail: detail))
        XCTAssertEqual(session.pluginReadDetails[plugin.id]?.appNames, ["GitHub App"])
        XCTAssertEqual(session.pluginReadDetails[plugin.id]?.appTemplateNames, ["GitHub template"])
        XCTAssertEqual(session.pluginReadDetails[plugin.id]?.mcpServerNames, ["github-mcp"])
        XCTAssertEqual(session.pluginReadDetails[plugin.id]?.skillNames, ["github:triage"])
        XCTAssertEqual(session.pluginReadDetails[plugin.id]?.hookNames, ["sessionStart: prepare"])
        XCTAssertTrue(session.loadingPluginReadIDs.isEmpty)
        XCTAssertNil(session.pluginReadErrors[plugin.id])
    }

    func testReadFailureStaysSeparateFromListInventory() {
        var session = CodexIntegrationCatalogSession()
        session.beginPluginRead(id: "official:github")
        session.failPluginRead(id: "official:github", message: "detail unavailable")
        XCTAssertEqual(session.pluginReadErrors["official:github"], "detail unavailable")
        XCTAssertTrue(session.loadingPluginReadIDs.isEmpty)
    }
}
