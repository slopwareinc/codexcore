import AppKit
import SwiftUI
import Testing

@testable import CodexCoreUI

/// Regression coverage for the bug behind a solid-black sidebar row in a
/// light window: `NSColor(someAdaptiveColor)` resolves against whatever
/// appearance happens to be current *process-wide*, not the caller's,
/// unless the resolution is pinned with `performAsCurrentDrawingAppearance`.
///
/// Every test here deliberately sets the *wrong* ambient appearance before
/// resolving, to prove `CodexAppKitColor.resolve` ignores it and returns the
/// requested one anyway.
@MainActor
struct CodexAppKitColorResolutionTests {
    private let pair = CodexColorPair(light: 0xFFFFFF, dark: 0x000000)

    @Test
    func resolvesLightRegardlessOfAmbientAppearance() {
        withAmbientAppearance(.darkAqua) {
            let resolved = CodexAppKitColor.resolve(pair.color, for: ColorScheme.light)
            #expect(isWhite(resolved), "expected white, got \(resolved)")
        }
    }

    @Test
    func resolvesDarkRegardlessOfAmbientAppearance() {
        withAmbientAppearance(.aqua) {
            let resolved = CodexAppKitColor.resolve(pair.color, for: ColorScheme.dark)
            #expect(isBlack(resolved), "expected black, got \(resolved)")
        }
    }

    @Test
    func resolvesAgainstAnExplicitNSAppearanceRegardlessOfAmbientAppearance() {
        withAmbientAppearance(.aqua) {
            let resolved = CodexAppKitColor.resolve(
                pair.color,
                for: NSAppearance(named: .darkAqua)
            )
            #expect(isBlack(resolved), "expected black, got \(resolved)")
        }
    }

    @Test
    func lightAndDarkResolutionsOfTheSameAdaptiveColorDiffer() {
        let light = CodexAppKitColor.resolve(pair.color, for: ColorScheme.light)
        let dark = CodexAppKitColor.resolve(pair.color, for: ColorScheme.dark)
        #expect(isWhite(light))
        #expect(isBlack(dark))
    }

    @Test
    func everyThemeColorRoleResolvesDifferentlyBetweenAppearancesForADualFamily() {
        // Midnight's canvas genuinely differs between appearances (this is
        // what makes it a dual-appearance family in the first place); if
        // resolution silently pinned to one appearance, this would fail.
        let spec = CodexAgentThemePreset.midnight.palette
        let light = CodexAppKitColor.resolve(spec.canvas.color, for: ColorScheme.light)
        let dark = CodexAppKitColor.resolve(spec.canvas.color, for: ColorScheme.dark)
        #expect(!colorsApproximatelyEqual(light, dark))
    }

    // MARK: - Helpers

    /// Runs `body` with the process's default appearance temporarily set to
    /// `appearance`, simulating the exact condition that caused the bug:
    /// resolving a color while the *ambient* appearance disagrees with the
    /// one actually wanted.
    private func withAmbientAppearance(_ name: NSAppearance.Name, _ body: () -> Void) {
        let previous = NSAppearance.current
        NSAppearance.current = NSAppearance(named: name)
        defer { NSAppearance.current = previous }
        body()
    }

    private func isWhite(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        return rgb.redComponent > 0.95 && rgb.greenComponent > 0.95 && rgb.blueComponent > 0.95
    }

    private func isBlack(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        return rgb.redComponent < 0.05 && rgb.greenComponent < 0.05 && rgb.blueComponent < 0.05
    }

    private func colorsApproximatelyEqual(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.02
            && abs(a.greenComponent - b.greenComponent) < 0.02
            && abs(a.blueComponent - b.blueComponent) < 0.02
    }
}
