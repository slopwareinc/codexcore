import SwiftUI

// The built-in theme families.
//
// Each is a hue family with a light and a dark rendering, so the preset picks
// the *character* of the app and the appearance mode picks light or dark. The
// surfaces stay low-chroma and the accents carry the identity; a theme whose
// backgrounds are saturated stops being usable after ten minutes of reading
// code in it.
//
// Contrast intent for every family: `textPrimary` on `canvas` clears WCAG AA
// for body text, `textSecondary` clears AA, and `textTertiary` is reserved for
// non-essential detail. `accentText` — not `accent` — is the accent that appears
// as text, because a fill accent bright enough to sit under white glyphs is
// rarely legible on the page itself.

public extension CodexPaletteSpec {
    /// Neutral graphite. The default: no hue, so nothing competes with syntax
    /// highlighting or diff colors.
    static var slate: CodexPaletteSpec {
        CodexPaletteSpec(
            canvas: .init(light: 0xF7F7F8, dark: 0x080809),
            surface: .init(light: 0xFFFFFF, dark: 0x101011),
            surfaceSunken: .init(light: 0xEFEFF1, dark: 0x070708),
            surfaceElevated: .init(light: 0xFFFFFF, dark: 0x18181A),
            textPrimary: .init(light: 0x18181B, dark: 0xFAFAFA),
            textSecondary: .init(light: 0x52525B, dark: 0xA8A8B0),
            textTertiary: .init(light: 0x7E7E88, dark: 0x76767E),
            accent: .init(light: 0x5B5BD6, dark: 0x8189FF),
            accentStrong: .init(light: 0x4444B8, dark: 0x9AA0FF),
            accentText: .init(light: 0x4A4ABF, dark: 0x9EA4FF),
            accentSoft: .init(light: 0xE8E8FB, dark: 0x232544),
            onAccent: .init(light: 0xFFFFFF, dark: 0x0B0B16),
            border: .init(light: 0x14000000, dark: 0x16FFFFFF),
            borderStrong: .init(light: 0x28000000, dark: 0x2EFFFFFF),
            userBubble: .init(light: 0x0D000000, dark: 0x0FFFFFFF),
            userBubbleStroke: .init(light: 0x14000000, dark: 0x14FFFFFF),
            codeBackground: .init(light: 0xF4F4F6, dark: 0x0B0C10),
            codeHeader: .init(light: 0xE9E9ED, dark: 0x14161C),
            codeText: .init(light: 0x27272E, dark: 0xD6DBE4),
            codeFaint: .init(light: 0x7A7A85, dark: 0x8A93A4),
            success: .init(light: 0x15803D, dark: 0x44D17E),
            warning: .init(light: 0xB45309, dark: 0xE7A23C),
            danger: .init(light: 0xC62828, dark: 0xFF6B66),
            running: .init(light: 0x2563EB, dark: 0x5C9BFF),
            tool: .init(light: 0x7C3AED, dark: 0xA78BFA)
        )
    }

    /// Cool deep blue. The most "night" of the families without going black.
    static var midnight: CodexPaletteSpec {
        CodexPaletteSpec(
            canvas: .init(light: 0xF1F4FA, dark: 0x03050A),
            surface: .init(light: 0xFFFFFF, dark: 0x080C16),
            surfaceSunken: .init(light: 0xE6EBF5, dark: 0x040711),
            surfaceElevated: .init(light: 0xFFFFFF, dark: 0x10182B),
            textPrimary: .init(light: 0x101728, dark: 0xF4F7FF),
            textSecondary: .init(light: 0x475069, dark: 0xB4BED4),
            textTertiary: .init(light: 0x77809A, dark: 0x707B94),
            accent: .init(light: 0x0E7490, dark: 0x6EE7F9),
            accentStrong: .init(light: 0x0A5A70, dark: 0x8CEEFB),
            accentText: .init(light: 0x0C6A85, dark: 0x8CEEFB),
            accentSoft: .init(light: 0xD6EEF5, dark: 0x11303A),
            onAccent: .init(light: 0xFFFFFF, dark: 0x061016),
            border: .init(light: 0x14101728, dark: 0x16FFFFFF),
            borderStrong: .init(light: 0x30101728, dark: 0x30FFFFFF),
            userBubble: .init(light: 0x0F0E7490, dark: 0x14223B),
            userBubbleStroke: .init(light: 0x240E7490, dark: 0x2A6EE7F9),
            codeBackground: .init(light: 0xF0F3FA, dark: 0x050814),
            codeHeader: .init(light: 0xE2E8F4, dark: 0x0D1426),
            codeText: .init(light: 0x1C2438, dark: 0xDBEAFE),
            codeFaint: .init(light: 0x78829C, dark: 0x74819C),
            success: .init(light: 0x0F766E, dark: 0x34D399),
            warning: .init(light: 0xA16207, dark: 0xFBBF24),
            danger: .init(light: 0xBE123C, dark: 0xFB7185),
            running: .init(light: 0x0284C7, dark: 0x38BDF8),
            tool: .init(light: 0x7E22CE, dark: 0xC084FC)
        )
    }

    /// Warm sand. Paper-like in light, lamplit in dark.
    static var warmSand: CodexPaletteSpec {
        CodexPaletteSpec(
            canvas: .init(light: 0xF6F1E9, dark: 0x0D0A08),
            surface: .init(light: 0xFFFCF7, dark: 0x15100D),
            surfaceSunken: .init(light: 0xEDE6DA, dark: 0x0A0807),
            surfaceElevated: .init(light: 0xFFFFFF, dark: 0x211A16),
            textPrimary: .init(light: 0x2A2118, dark: 0xFFF8EF),
            textSecondary: .init(light: 0x5C5044, dark: 0xD8C9B8),
            textTertiary: .init(light: 0x8A7B6B, dark: 0x9A8976),
            accent: .init(light: 0xB4651B, dark: 0xF4A261),
            accentStrong: .init(light: 0x8F4E12, dark: 0xF8B87E),
            accentText: .init(light: 0x9A551A, dark: 0xF8B87E),
            accentSoft: .init(light: 0xF6E4CE, dark: 0x3A2A1F),
            onAccent: .init(light: 0xFFFFFF, dark: 0x20130B),
            border: .init(light: 0x1A2A2118, dark: 0x16FFF8EF),
            borderStrong: .init(light: 0x332A2118, dark: 0x30FFF8EF),
            userBubble: .init(light: 0x12B4651B, dark: 0x2A241F),
            userBubbleStroke: .init(light: 0x26B4651B, dark: 0x26F4A261),
            codeBackground: .init(light: 0xF3EDE3, dark: 0x120F0D),
            codeHeader: .init(light: 0xE7DFD1, dark: 0x201A16),
            codeText: .init(light: 0x30271D, dark: 0xF8E8D5),
            codeFaint: .init(light: 0x8A7B6B, dark: 0x9A8976),
            success: .init(light: 0x3F7D53, dark: 0x74C69D),
            warning: .init(light: 0xB4651B, dark: 0xF4A261),
            danger: .init(light: 0xB03A22, dark: 0xE76F51),
            running: .init(light: 0x2E6FA8, dark: 0x90CAF9),
            tool: .init(light: 0x7A559E, dark: 0xC4A7E7)
        )
    }

    /// Muted green. Low-chroma and restful; the calmest of the families.
    static var sage: CodexPaletteSpec {
        CodexPaletteSpec(
            canvas: .init(light: 0xF0F3EB, dark: 0x090C08),
            surface: .init(light: 0xFAFBF6, dark: 0x11150F),
            surfaceSunken: .init(light: 0xE7EBDF, dark: 0x070A06),
            surfaceElevated: .init(light: 0xFFFFFF, dark: 0x1A2018),
            textPrimary: .init(light: 0x242C22, dark: 0xF2F0E8),
            textSecondary: .init(light: 0x54604F, dark: 0xBCC5B7),
            textTertiary: .init(light: 0x7D8878, dark: 0x8B9686),
            accent: .init(light: 0x4F6B37, dark: 0xA8C084),
            accentStrong: .init(light: 0x3B5228, dark: 0xBCD39B),
            accentText: .init(light: 0x425C2D, dark: 0xBCD39B),
            accentSoft: .init(light: 0xDDE6CB, dark: 0x2C3826),
            onAccent: .init(light: 0xFFFFFF, dark: 0x121A0D),
            border: .init(light: 0x1A242C22, dark: 0x16F2F0E8),
            borderStrong: .init(light: 0x33242C22, dark: 0x30F2F0E8),
            userBubble: .init(light: 0x124F6B37, dark: 0x232B20),
            userBubbleStroke: .init(light: 0x264F6B37, dark: 0x26A8C084),
            codeBackground: .init(light: 0xEFF2E9, dark: 0x0D100C),
            codeHeader: .init(light: 0xE2E7D8, dark: 0x181D16),
            codeText: .init(light: 0x2A3227, dark: 0xE4EADC),
            codeFaint: .init(light: 0x7D8878, dark: 0x8B9686),
            success: .init(light: 0x3F7D53, dark: 0x7FC99B),
            warning: .init(light: 0x9A6B12, dark: 0xE3B457),
            danger: .init(light: 0xB03A2E, dark: 0xE58575),
            running: .init(light: 0x2E6FA8, dark: 0x8CB8DE),
            tool: .init(light: 0x6F5A94, dark: 0xB7A5D6)
        )
    }

    /// Dusty rose. Warm without the sand family's yellow.
    static var rose: CodexPaletteSpec {
        CodexPaletteSpec(
            canvas: .init(light: 0xF6EEEC, dark: 0x0E0A0A),
            surface: .init(light: 0xFDF6F4, dark: 0x171111),
            surfaceSunken: .init(light: 0xEDE0DC, dark: 0x0B0808),
            surfaceElevated: .init(light: 0xFFFFFF, dark: 0x221919),
            textPrimary: .init(light: 0x2E2220, dark: 0xF9EFEC),
            textSecondary: .init(light: 0x5F4E4B, dark: 0xD3BEBA),
            textTertiary: .init(light: 0x8C7671, dark: 0x9C8682),
            accent: .init(light: 0xA84A3C, dark: 0xE0928A),
            accentStrong: .init(light: 0x853729, dark: 0xEDA9A0),
            accentText: .init(light: 0x8F3E30, dark: 0xEDA9A0),
            accentSoft: .init(light: 0xF6DAD4, dark: 0x3D2724),
            onAccent: .init(light: 0xFFFFFF, dark: 0x1E0F0D),
            border: .init(light: 0x1A2E2220, dark: 0x16F9EFEC),
            borderStrong: .init(light: 0x332E2220, dark: 0x30F9EFEC),
            userBubble: .init(light: 0x12A84A3C, dark: 0x2F2422),
            userBubbleStroke: .init(light: 0x26A84A3C, dark: 0x26E0928A),
            codeBackground: .init(light: 0xF4ECEA, dark: 0x100C0C),
            codeHeader: .init(light: 0xE8DBD8, dark: 0x1D1717),
            codeText: .init(light: 0x332624, dark: 0xEDE0DD),
            codeFaint: .init(light: 0x8C7671, dark: 0x9C8682),
            success: .init(light: 0x3F7D53, dark: 0x7FC99B),
            warning: .init(light: 0xA5690F, dark: 0xE5B45C),
            danger: .init(light: 0xB0322A, dark: 0xEE8074),
            running: .init(light: 0x2F6DA4, dark: 0x8FB9DD),
            tool: .init(light: 0x7A5391, dark: 0xC09FD3)
        )
    }

    /// Cool violet. The most colored of the families, still low-chroma.
    static var violet: CodexPaletteSpec {
        CodexPaletteSpec(
            canvas: .init(light: 0xF2EFF5, dark: 0x0B080F),
            surface: .init(light: 0xFAF7FC, dark: 0x15101A),
            surfaceSunken: .init(light: 0xE8E3EE, dark: 0x08060B),
            surfaceElevated: .init(light: 0xFFFFFF, dark: 0x1E1725),
            textPrimary: .init(light: 0x282334, dark: 0xF3EEF7),
            textSecondary: .init(light: 0x574F66, dark: 0xC5BACD),
            textTertiary: .init(light: 0x82798F, dark: 0x928699),
            accent: .init(light: 0x6A4C93, dark: 0xB59BD4),
            accentStrong: .init(light: 0x523873, dark: 0xC7B0E1),
            accentText: .init(light: 0x5A3F7F, dark: 0xC7B0E1),
            accentSoft: .init(light: 0xE6DDF2, dark: 0x33284A),
            onAccent: .init(light: 0xFFFFFF, dark: 0x150C22),
            border: .init(light: 0x1A282334, dark: 0x16F3EEF7),
            borderStrong: .init(light: 0x33282334, dark: 0x30F3EEF7),
            userBubble: .init(light: 0x126A4C93, dark: 0x282132),
            userBubbleStroke: .init(light: 0x266A4C93, dark: 0x26B59BD4),
            codeBackground: .init(light: 0xF1EDF6, dark: 0x0F0D13),
            codeHeader: .init(light: 0xE4DEEC, dark: 0x1A1620),
            codeText: .init(light: 0x2D2739, dark: 0xE7E0EE),
            codeFaint: .init(light: 0x82798F, dark: 0x928699),
            success: .init(light: 0x3B7A57, dark: 0x7FC79E),
            warning: .init(light: 0x9C6A15, dark: 0xE2B25E),
            danger: .init(light: 0xAE3448, dark: 0xEB8296),
            running: .init(light: 0x3A64AE, dark: 0x93AFE4),
            tool: .init(light: 0x7B4B9E, dark: 0xC79EE0)
        )
    }

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
