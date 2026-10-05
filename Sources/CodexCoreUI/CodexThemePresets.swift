import SwiftUI

// The built-in theme families.
//
// Each family is a `CodexThemeSeed`: a neutral tint, an accent, and the hues of
// its atmosphere. `CodexThemeGenerator` derives every role for both appearances
// from it and solves text lightness against WCAG targets, so a family is a
// statement of character — four numbers and three hues — rather than 66 hex
// values that each have to be re-verified by hand.
//
// Surfaces stay low-chroma and the accent and atmosphere carry the identity; a
// theme whose backgrounds are saturated stops being usable after ten minutes of
// reading code in it.

public extension CodexThemeSeed {
    /// Neutral graphite with an indigo accent. The default: surfaces carry no
    /// visible hue, so nothing competes with syntax or diff colors.
    static let graphite = CodexThemeSeed(
        neutralHue: 275, neutralChroma: 0.006,
        accentHue: 274, accentChroma: 0.15,
        atmosphereHues: [274, 232, 318], atmosphereChroma: 0.10
    )

    /// Deep sea blue with a cyan-teal accent.
    static let tide = CodexThemeSeed(
        neutralHue: 245, neutralChroma: 0.018,
        accentHue: 212, accentChroma: 0.12,
        atmosphereHues: [212, 262, 182], atmosphereChroma: 0.11
    )

    /// Warm paper and lamplight, with an amber accent.
    static let ember = CodexThemeSeed(
        neutralHue: 60, neutralChroma: 0.012,
        accentHue: 50, accentChroma: 0.15,
        atmosphereHues: [50, 22, 82], atmosphereChroma: 0.11
    )

    /// Muted forest green. The calmest family.
    static let moss = CodexThemeSeed(
        neutralHue: 135, neutralChroma: 0.012,
        accentHue: 140, accentChroma: 0.11,
        atmosphereHues: [140, 178, 102], atmosphereChroma: 0.10
    )

    /// Soft coral pink, warm without yellow.
    static let bloom = CodexThemeSeed(
        neutralHue: 15, neutralChroma: 0.012,
        accentHue: 12, accentChroma: 0.14,
        atmosphereHues: [12, 342, 48], atmosphereChroma: 0.11
    )

    /// Orchid violet.
    static let orchid = CodexThemeSeed(
        neutralHue: 305, neutralChroma: 0.014,
        accentHue: 305, accentChroma: 0.14,
        atmosphereHues: [305, 265, 345], atmosphereChroma: 0.11
    )

    /// Night sky: blue-black surfaces, a mint accent, and green-violet light.
    static let aurora = CodexThemeSeed(
        neutralHue: 255, neutralChroma: 0.012,
        accentHue: 168, accentChroma: 0.12,
        atmosphereHues: [168, 292, 215], atmosphereChroma: 0.12
    )
}

public extension CodexPaletteSpec {
    /// Maximum contrast, still a theme rather than a different app: pure
    /// canvases, full-strength text, unmistakable borders.
    static var highContrast: CodexPaletteSpec {
        CodexPaletteSpec(
            canvas: .init(light: 0xFFFFFF, dark: 0x000000),
            surface: .init(light: 0xFFFFFF, dark: 0x000000),
            surfaceSunken: .init(light: 0xF0F0F0, dark: 0x101010),
            surfaceElevated: .init(light: 0xFFFFFF, dark: 0x1A1A1A),
            textPrimary: .init(light: 0x000000, dark: 0xFFFFFF),
            textSecondary: .init(light: 0x1F1F1F, dark: 0xEDEDED),
            textTertiary: .init(light: 0x3D3D3D, dark: 0xC8C8C8),
            accent: .init(light: 0x0000D6, dark: 0xFFD84D),
            accentStrong: .init(light: 0x0000A8, dark: 0xFFE480),
            accentText: .init(light: 0x0000C2, dark: 0xFFE480),
            accentSoft: .init(light: 0xE0E0FF, dark: 0x332A00),
            onAccent: .init(light: 0xFFFFFF, dark: 0x000000),
            border: .init(light: 0x59000000, dark: 0x59FFFFFF),
            borderStrong: .init(light: 0x000000, dark: 0xFFFFFF),
            userBubble: .init(light: 0x14000000, dark: 0x1FFFFFFF),
            userBubbleStroke: .init(light: 0x000000, dark: 0xFFFFFF),
            codeBackground: .init(light: 0xFFFFFF, dark: 0x000000),
            codeHeader: .init(light: 0xEDEDED, dark: 0x111111),
            codeText: .init(light: 0x000000, dark: 0xFFFFFF),
            codeFaint: .init(light: 0x3D3D3D, dark: 0xC8C8C8),
            success: .init(light: 0x006622, dark: 0x00FF8A),
            warning: .init(light: 0x7A4A00, dark: 0xFFD84D),
            danger: .init(light: 0xB00000, dark: 0xFF4D4D),
            running: .init(light: 0x00478F, dark: 0x4DD2FF),
            tool: .init(light: 0x6A00A8, dark: 0xD98CFF)
        )
    }
}
