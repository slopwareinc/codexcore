import Foundation
import Testing

@testable import CodexCoreUI

/// The sidebar used to have its own font-size setting, independent of the
/// app-wide `uiFontSize`, and its font tokens ignored the user's chosen text
/// family entirely (`FontToken.font` always called `.system(...)`). Both are
/// now unified: the sidebar mirrors the rest of the app exactly, with no
/// setting of its own.
struct CodexSidebarTypographyUnificationTests {
    @Test
    func sidebarBaseSizeTracksTheAppWideFontSize() {
        let small = CodexAgentTheme.Fonts.official(baseTextSize: 12)
        let large = CodexAgentTheme.Fonts.official(baseTextSize: 17)

        #expect(small.sidebar.chatTitle.size == 12)
        #expect(large.sidebar.chatTitle.size == 17)
        #expect(small.sidebar.chatTitle.size != large.sidebar.chatTitle.size)
    }

    @Test
    func iconTokensStayOffsetFromTitleTokensAtAnyBaseSize() {
        // The token offsets (title at +0, icon at -1, action icon at -6.5) are
        // relative, so the *shape* of the scale is preserved while the base
        // size still moves — this was the one thing the old independent
        // sidebar slider got right, and unification must not lose it.
        for base in [11.0, 14.0, 18.0] {
            let fonts = CodexAgentTheme.Fonts.official(baseTextSize: base)
            #expect(fonts.sidebar.commandIcon.size == fonts.sidebar.commandTitle.size - 1)
            #expect(fonts.sidebar.projectIcon.size == fonts.sidebar.projectTitle.size - 1)
        }
    }

    @Test
    func sidebarFontFamilyMatchesTheAppFontFamilyWhenSet() {
        let withFamily = CodexAgentTheme.Fonts.official(baseTextSize: 14, textFamily: "Georgia")
        #expect(withFamily.sidebar.chatTitle.family == "Georgia")
        #expect(withFamily.sidebar.projectTitle.family == "Georgia")
        #expect(withFamily.sidebar.sectionHeader.family == "Georgia")
    }

    @Test
    func sidebarFontFamilyIsSystemWhenNoneIsChosen() {
        let systemFonts = CodexAgentTheme.Fonts.official(baseTextSize: 14)
        #expect(systemFonts.sidebar.chatTitle.family == nil)
    }

    @Test
    func liveAppearanceSettingsAlsoUnifySidebarSizeAndFamily() {
        // The actual runtime path: CodexAppearanceSettings.agentTheme(uiFontSize:reduceMotion:)
        // is what CodexCoreAppModel.theme calls.
        let settings = CodexAppearanceSettings(uiFontSize: 16, textFontFamily: "Avenir Next")
        let theme = settings.agentTheme(uiFontSize: settings.uiFontSize, reduceMotion: false)

        #expect(theme.fonts.sidebar.chatTitle.size == 16)
        #expect(theme.fonts.sidebar.chatTitle.family == "Avenir Next")
    }

    @Test
    func fontTokenRendersInItsFamilyWhenOneIsSet() {
        // FontToken.font used to ignore `family` entirely (it didn't exist);
        // this is the actual rendering path every sidebar row calls through
        // `theme.fonts.sidebar.<token>.font`.
        let withFamily = CodexAgentTheme.FontToken(size: 14, weight: .semibold, family: "Georgia")
        let withoutFamily = CodexAgentTheme.FontToken(size: 14, weight: .semibold)
        #expect(withFamily.font != withoutFamily.font)
    }
}
