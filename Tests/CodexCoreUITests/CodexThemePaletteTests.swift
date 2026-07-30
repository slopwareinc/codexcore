import SwiftUI
import Testing

@testable import CodexCoreUI

@MainActor
struct CodexThemePaletteTests {
    @Test
    func everyPresetRendersInBothAppearances() {
        for preset in CodexAgentThemePreset.allCases {
            let palette = preset.palette
            // A family that resolved to the same canvas in both appearances
            // would be a single-appearance skin again.
            #expect(
                palette.canvas.light != palette.canvas.dark,
                "\(preset.displayName) has an appearance-independent canvas"
            )
            #expect(
                palette.textPrimary.light != palette.textPrimary.dark,
                "\(preset.displayName) has an appearance-independent text color"
            )
        }
    }

    @Test
    func lightPalettesAreLightAndDarkPalettesAreDark() {
        for preset in CodexAgentThemePreset.allCases {
            let palette = preset.palette
            #expect(
                relativeLuminance(palette.canvas.light) > relativeLuminance(palette.textPrimary.light),
                "\(preset.displayName) light canvas is not lighter than its text"
            )
            #expect(
                relativeLuminance(palette.canvas.dark) < relativeLuminance(palette.textPrimary.dark),
                "\(preset.displayName) dark canvas is not darker than its text"
            )
        }
    }

    @Test
    func bodyTextClearsContrastFloorOnCanvasInBothAppearances() {
        for preset in CodexAgentThemePreset.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let ratio = contrastRatio(
                    preset.palette.textPrimary.value(for: scheme),
                    preset.palette.canvas.value(for: scheme)
                )
                #expect(
                    ratio >= 4.5,
                    "\(preset.displayName) \(scheme) body text contrast is \(ratio), below WCAG AA 4.5"
                )
            }
        }
    }

    @Test
    func secondaryTextClearsContrastFloorOnCanvasInBothAppearances() {
        for preset in CodexAgentThemePreset.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let ratio = contrastRatio(
                    preset.palette.textSecondary.value(for: scheme),
                    preset.palette.canvas.value(for: scheme)
                )
                #expect(
                    ratio >= 4.5,
                    "\(preset.displayName) \(scheme) secondary text contrast is \(ratio), below WCAG AA 4.5"
                )
            }
        }
    }

    @Test
    func accentTextIsLegibleOnCanvasWhereAccentFillNeedNotBe() {
        // The distinction that lets a bright fill accent coexist with readable
        // accent-colored text: `accentText` is held to the text floor.
        for preset in CodexAgentThemePreset.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let ratio = contrastRatio(
                    preset.palette.accentText.value(for: scheme),
                    preset.palette.canvas.value(for: scheme)
                )
                #expect(
                    ratio >= 3.0,
                    "\(preset.displayName) \(scheme) accentText contrast is \(ratio), below 3.0"
                )
            }
        }
    }

    @Test
    func onAccentIsLegibleAgainstItsAccentFill() {
        // The bug this replaces: onAccent was effectively hardcoded white, so a
        // pale or dark accent produced white-on-pastel glyphs.
        for preset in CodexAgentThemePreset.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let ratio = contrastRatio(
                    preset.palette.onAccent.value(for: scheme),
                    preset.palette.accent.value(for: scheme)
                )
                #expect(
                    ratio >= 3.0,
                    "\(preset.displayName) \(scheme) onAccent contrast is \(ratio), below 3.0"
                )
            }
        }
    }

    @Test
    func alphaEncodingDistinguishesOpaqueFromTranslucent() {
        // 0xRRGGBB is opaque; 0xAARRGGBB carries alpha.
        let opaque = CodexColorPair(0x336699)
        let translucent = CodexColorPair(0x80336699)
        #expect(opacity(of: opaque.light) == 1.0)
        #expect(abs(opacity(of: translucent.light) - 128.0 / 255.0) < 0.01)
    }

    @Test
    func resolvedColorsPickTheRequestedAppearance() {
        let spec = CodexAgentThemePreset.midnight.palette
        #expect(spec.canvas.resolved(.light) != spec.canvas.resolved(.dark))
        #expect(spec.canvas.value(for: .light) == spec.canvas.light)
        #expect(spec.canvas.value(for: .dark) == spec.canvas.dark)
    }

    @Test
    func legacyPresetRawValuesSurviveSoStoredSettingsDoNotReset() {
        // These raw values are persisted in the appearance settings JSON.
        #expect(CodexAgentThemePreset(rawValue: "officialDark") == .officialDark)
        #expect(CodexAgentThemePreset(rawValue: "nativeLight") == .nativeLight)
        #expect(CodexAgentThemePreset(rawValue: "midnight") == .midnight)
        #expect(CodexAgentThemePreset(rawValue: "warmMinimal") == .warmMinimal)
        #expect(CodexAgentThemePreset(rawValue: "highContrast") == .highContrast)
    }

    @Test
    func decodingSettingsWithoutAppearanceModeKeepsTheOtherPreferences() throws {
        // The synthesized decoder would have thrown on the absent key and reset
        // every stored appearance preference.
        let stored = """
        {"preset":"midnight","reduceMotion":true,"uiFontSize":16,\
        "diffMarkerStyle":"signs","dockIconVariant":"codexDark","textFontFamily":"Georgia"}
        """
        let settings = try JSONDecoder().decode(
            CodexAppearanceSettings.self,
            from: Data(stored.utf8)
        )
        #expect(settings.preset == .midnight)
        #expect(settings.reduceMotion)
        #expect(settings.uiFontSize == 16)
        #expect(settings.diffMarkerStyle == .signs)
        #expect(settings.dockIconVariant == .codexDark)
        #expect(settings.textFontFamily == "Georgia")
        #expect(settings.appearanceMode == .system)
    }

    @Test
    func legacyDarkPresetKeepsItsAppearanceWhenNoModeWasStored() {
        // "Official Dark" implied an appearance in its name. An existing install
        // must not flip to light because palettes became dual.
        let stored = #"{"preset":"officialDark","reduceMotion":false,"uiFontSize":14}"#
        let settings = try? JSONDecoder().decode(
            CodexAppearanceSettings.self,
            from: Data(stored.utf8)
        )
        #expect(settings?.appearanceMode == .dark)

        let light = #"{"preset":"nativeLight","reduceMotion":false,"uiFontSize":14}"#
        let lightSettings = try? JSONDecoder().decode(
            CodexAppearanceSettings.self,
            from: Data(light.utf8)
        )
        #expect(lightSettings?.appearanceMode == .light)
    }

    @Test
    func appearanceModeSurvivesARoundTrip() throws {
        let settings = CodexAppearanceSettings(preset: .sage, appearanceMode: .light, uiFontSize: 15)
        let decoded = try JSONDecoder().decode(
            CodexAppearanceSettings.self,
            from: try JSONEncoder().encode(settings)
        )
        #expect(decoded == settings)
        #expect(decoded.appearanceMode == .light)
    }

    @Test
    func onlyHighContrastOptsOutOfGlass() {
        for preset in CodexAgentThemePreset.allCases {
            #expect(
                preset.theme.effects.usesLiquidGlass == (preset != .highContrast),
                "\(preset.displayName) has the wrong glass opt-out"
            )
        }
    }

    @Test
    func everyTypographyTokenTracksTheInterfaceFontSize() {
        // The whole point of the scale: the app scales, not only the sidebar.
        let small = CodexAgentTheme.Fonts.official(baseTextSize: 11)
        let large = CodexAgentTheme.Fonts.official(baseTextSize: 18)
        #expect(small.routeTitle != large.routeTitle)
        #expect(small.sheetTitle != large.sheetTitle)
        #expect(small.panelTitle != large.panelTitle)
        #expect(small.heroTitle != large.heroTitle)
        #expect(small.actionIcon != large.actionIcon)
        #expect(small.chipLabel != large.chipLabel)
    }

    @Test
    func glassRoleInteractivityIsAPropertyOfBeingAControl() {
        #expect(CodexGlassRole.control.isInteractive)
        #expect(CodexGlassRole.chip.isInteractive)
        // A container that merely holds controls must not flex when one is
        // pressed.
        #expect(!CodexGlassRole.chrome.isInteractive)
        #expect(!CodexGlassRole.panel.isInteractive)
        #expect(!CodexGlassRole.sheet.isInteractive)
        #expect(!CodexGlassRole.hud.isInteractive)
    }

    @Test
    func onlyTheHudRoleUsesTheClearVariant() {
        for role in CodexGlassRole.allCases {
            #expect(role.prefersClearVariant == (role == .hud))
        }
    }

    // MARK: - Contrast helpers (WCAG 2.1 relative luminance)

    private func opacity(of value: UInt32) -> Double {
        value <= 0xFFFFFF ? 1.0 : Double((value >> 24) & 0xFF) / 255.0
    }

    private func relativeLuminance(_ value: UInt32) -> Double {
        func channel(_ raw: UInt32) -> Double {
            let srgb = Double(raw) / 255.0
            return srgb <= 0.03928 ? srgb / 12.92 : pow((srgb + 0.055) / 1.055, 2.4)
        }
        let r = channel((value >> 16) & 0xFF)
        let g = channel((value >> 8) & 0xFF)
        let b = channel(value & 0xFF)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// Contrast of `foreground` over `background`, compositing the foreground's
    /// alpha onto the background first so translucent roles are judged as drawn.
    private func contrastRatio(_ foreground: UInt32, _ background: UInt32) -> Double {
        let alpha = opacity(of: foreground)
        let composited: UInt32
        if alpha >= 1.0 {
            composited = foreground & 0xFFFFFF
        } else {
            func blend(_ shift: UInt32) -> UInt32 {
                let f = Double((foreground >> shift) & 0xFF)
                let b = Double((background >> shift) & 0xFF)
                return UInt32((f * alpha + b * (1 - alpha)).rounded())
            }
            composited = (blend(16) << 16) | (blend(8) << 8) | blend(0)
        }
        let a = relativeLuminance(composited)
        let b = relativeLuminance(background & 0xFFFFFF)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
