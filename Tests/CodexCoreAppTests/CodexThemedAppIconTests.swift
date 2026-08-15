import AppKit
import SwiftUI
import Testing
@testable import CodexCoreApp
@testable import CodexCoreUI

@MainActor
@Suite("Theme-aligned app icon")
struct CodexThemedAppIconTests {
    @Test("Uses the approved rosette geometry and Slate tint")
    func approvedConfiguration() {
        #expect(CodexThemedAppIcon.internalScale == 0.87)
        #expect(CodexThemedAppIcon.gradientAngle == 265)
        #expect(CodexThemedAppIcon.tintValue(for: .official, colorScheme: .dark) == 0x7E9DA5)
    }

    @Test("Theme families and pinned icon appearances select palette accents")
    func themeTintSelection() {
        var settings = CodexAppearanceSettings(preset: .rose, appearanceMode: .system)
        #expect(
            CodexThemedAppIcon.tintValue(for: settings, colorScheme: .light)
                == CodexAgentThemePreset.rose.palette.accent.light
        )

        settings.dockIconVariant = .codexDark
        #expect(
            CodexThemedAppIcon.tintValue(for: settings, colorScheme: .light)
                == CodexAgentThemePreset.rose.palette.accent.dark
        )
    }

    @Test("Bundled master renders a full-resolution icon")
    func render() throws {
        let image = try #require(
            CodexThemedAppIcon.render(
                settings: CodexAppearanceSettings(preset: .sage, appearanceMode: .dark),
                colorScheme: .dark
            )
        )
        #expect(image.size == CodexThemedAppIcon.canvasSize)
    }
}
