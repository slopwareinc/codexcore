import SwiftUI

// Ported from T3 Code's apps/web/src/index.css at
// 3e6b45028ceec5820dacb37dc3852470ebdc9411.
// Copyright (c) 2026 T3 Tools Inc. MIT license; see THIRD_PARTY_NOTICES.md.

public extension CodexPaletteSpec {
    /// The upstream default zinc/light and neutral/black palette. Kept separate
    /// from the generated hue families so its source values remain reviewable.
    static var t3Code: CodexPaletteSpec {
        let primary = CodexColorPair(
            light: OKLCH(0.488, 0.217, 264).rgb,
            dark: OKLCH(0.571, 0.21, 264).rgb
        )
        let text = CodexColorPair(light: 0x27272A, dark: 0xF5F5F5)
        let muted = CodexColorPair(light: 0x71717A, dark: 0x828282)
        return CodexPaletteSpec(
            canvas: .init(light: OKLCH(0.992, 0, 0).rgb, dark: 0x0A0A0A),
            surface: .init(light: 0xFFFFFF, dark: 0x111111),
            surfaceSunken: .init(light: 0xFAFAFA, dark: 0x111111),
            surfaceElevated: .init(light: 0xFFFFFF, dark: 0x111111),
            textPrimary: text,
            textSecondary: muted,
            textTertiary: muted,
            accent: primary,
            accentStrong: .init(light: OKLCH(0.44, 0.217, 264).rgb, dark: OKLCH(0.52, 0.21, 264).rgb),
            accentText: .init(light: primary.light, dark: 0x51A2FF),
            accentSoft: .init(light: 0xF4F4F5, dark: 0x0AFFFFFF),
            onAccent: .init(0xFFFFFF),
            border: .init(light: 0xE4E4E7, dark: 0x0FFFFFFF),
            borderStrong: .init(light: 0xD4D4D8, dark: 0x14FFFFFF),
            userBubble: .init(light: 0xF4F4F5, dark: 0x0AFFFFFF),
            userBubbleStroke: .init(light: 0xF4F4F5, dark: 0x01FFFFFF),
            codeBackground: .init(light: 0xFEFEFE, dark: 0x111111),
            codeHeader: .init(light: 0xFAFAFA, dark: 0x151515),
            codeText: text,
            codeFaint: muted,
            success: .init(light: 0x007A55, dark: 0x00D492),
            warning: .init(light: 0xBB4D00, dark: 0xFFBA00),
            danger: .init(light: 0xC10007, dark: 0xFF6467),
            running: .init(light: 0x1447E6, dark: 0x51A2FF),
            tool: muted,
            codeKeyword: .init(light: 0xCF222E, dark: 0xFF7B72),
            codeString: .init(light: 0x0A3069, dark: 0xA5D6FF),
            codeComment: muted,
            codeNumber: .init(light: 0x0550AE, dark: 0x79C0FF),
            scrim: .init(0x000000),
            shadow: .init(0x000000),
            hover: text,
            selection: text
        )
    }
}
