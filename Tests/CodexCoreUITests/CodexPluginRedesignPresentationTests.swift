import XCTest
@testable import CodexCoreUI

final class CodexPluginRedesignPresentationTests: XCTestCase {
    func testBrowseLayoutSwitchesAtDocumentedResponsiveBoundary() {
        XCTAssertEqual(CodexPluginBrowseLayoutPolicy.columnCount(availableWidth: 679), 1)
        XCTAssertEqual(CodexPluginBrowseLayoutPolicy.columnCount(availableWidth: 680), 2)
        XCTAssertEqual(CodexPluginBrowseLayoutPolicy.columns(availableWidth: 500).count, 1)
        XCTAssertEqual(CodexPluginBrowseLayoutPolicy.columns(availableWidth: 900).count, 2)
    }

    func testPluginStatusesAreExplicitAndDistinguishAdministrativeState() {
        XCTAssertEqual(CodexPluginStatusPresentation.label(for: plugin(installed: true, enabled: true), isPending: false), "Enabled")
        XCTAssertEqual(CodexPluginStatusPresentation.label(for: plugin(installed: true, enabled: false), isPending: false), "Disabled")
        XCTAssertEqual(
            CodexPluginStatusPresentation.label(
                for: plugin(installed: true, enabled: true, installPolicy: "INSTALLED_BY_DEFAULT", sourceType: "remote"),
                isPending: false
            ),
            "Installed by admin"
        )
        XCTAssertEqual(
            CodexPluginStatusPresentation.label(
                for: plugin(installPolicy: "NOT_AVAILABLE", availability: "DISABLED_BY_ADMIN"),
                isPending: false
            ),
            "Disabled by admin"
        )
        XCTAssertEqual(CodexPluginStatusPresentation.label(for: plugin(), isPending: true), "Updating")
        XCTAssertEqual(CodexPluginStatusPresentation.label(for: plugin(installPolicy: "AVAILABLE"), isPending: false), "Available")
        XCTAssertEqual(CodexPluginStatusPresentation.label(for: plugin(), isPending: false), "Unavailable in this context")
    }

    func testAppStatusPreservesRuntimeUnknownInsteadOfInventingAToggleState() {
        XCTAssertEqual(CodexPluginStatusPresentation.appLabel(for: .init(id: "installed", name: "Installed", isInstalled: true)), "Installed")
        XCTAssertEqual(CodexPluginStatusPresentation.appLabel(for: .init(id: "enabled", name: "Enabled", isInstalled: true, runtimeEnabled: true)), "Enabled")
        XCTAssertEqual(CodexPluginStatusPresentation.appLabel(for: .init(id: "disabled", name: "Disabled", isInstalled: true, runtimeEnabled: false)), "Disabled")
        XCTAssertEqual(CodexPluginStatusPresentation.appLabel(for: .init(id: "blocked", name: "Blocked", isAccessible: false)), "Unavailable")
        XCTAssertEqual(CodexPluginStatusPresentation.appLabel(for: .init(id: "disabled-catalog", name: "Disabled Catalog", isAccessible: true, isEnabled: false)), "Disabled")
        XCTAssertEqual(CodexPluginStatusPresentation.appLabel(for: .init(id: "unknown", name: "Unknown", isAccessible: nil, isEnabled: nil)), "Status unknown")
    }

    private func plugin(
        installed: Bool = false,
        enabled: Bool = false,
        installPolicy: String = "NOT_AVAILABLE",
        availability: String? = nil,
        sourceType: String? = nil
    ) -> CodexPluginSummary {
        CodexPluginSummary(
            id: "plugin-\(UUID().uuidString)",
            name: "plugin",
            marketplaceName: "official",
            installed: installed,
            enabled: enabled,
            installPolicy: installPolicy,
            availability: availability,
            sourceType: sourceType
        )
    }
}
