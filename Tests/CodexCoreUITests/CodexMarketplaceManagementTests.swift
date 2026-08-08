import XCTest
@testable import CodexCore
@testable import CodexCoreUI

final class CodexMarketplaceManagementTests: XCTestCase {
    func testMarketplaceSummariesComeOnlyFromAuthoritativePluginListEntries() {
        let response = CodexJSONValue.dictionary([
            "marketplaces": .array([
                .dictionary([
                    "name": .string("team-tools"),
                    "interface": .dictionary(["displayName": .string("Team Tools")]),
                    "path": .string("/registered/team-tools/marketplace.json"),
                    "plugins": .array([.dictionary([:]), .dictionary([:])])
                ]),
                .dictionary([
                    "name": .string("empty-registered"),
                    "plugins": .array([])
                ]),
                .dictionary(["path": .string("/cache/guess/marketplace.json")]),
                .dictionary(["name": .string("missing-required-plugins")])
            ])
        ])

        let summaries = CodexMarketplaceSummary.marketplaces(from: response)

        XCTAssertEqual(summaries.map(\.name), ["empty-registered", "team-tools"])
        XCTAssertEqual(summaries.first(where: { $0.name == "team-tools" }), .init(
            name: "team-tools",
            displayName: "Team Tools",
            path: "/registered/team-tools/marketplace.json",
            pluginCount: 2
        ))
        XCTAssertEqual(summaries.first(where: { $0.name == "empty-registered" })?.pluginCount, 0)
        XCTAssertTrue(CodexMarketplaceSummary.marketplaces(from: .dictionary([:])).isEmpty)
    }

    func testCatalogSessionKeepsMarketplaceInventoryAndAuthoritativeCount() {
        var session = CodexIntegrationCatalogSession()
        session.applyPluginResponse(.dictionary([
            "marketplaces": .array([
                .dictionary([
                    "name": .string("registered"),
                    "plugins": .array([.dictionary(["name": .string("one")])])
                ])
            ])
        ]))

        XCTAssertEqual(session.marketplaces, [.init(name: "registered", pluginCount: 1)])
    }

    func testMarketplaceProtocolMutationsUseGeneratedParameterTypes() {
        let marketplace = CodexMarketplaceSummary(name: "team", displayName: "Team", pluginCount: 3)
        let target = CodexMarketplaceActionTarget(marketplace: marketplace)

        XCTAssertEqual(CodexPluginProtocolMutation.marketplaceAddParams(source: "https://example.com/team.git"),
                       CodexSchemaMarketplaceAddParams(source: "https://example.com/team.git"))
        XCTAssertEqual(CodexPluginProtocolMutation.marketplaceUpgradeParams(for: target),
                       CodexSchemaMarketplaceUpgradeParams(marketplaceName: "team"))
        XCTAssertEqual(CodexPluginProtocolMutation.marketplaceRemoveParams(for: target),
                       CodexSchemaMarketplaceRemoveParams(marketplaceName: "team"))
    }
}
