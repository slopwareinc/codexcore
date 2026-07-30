#if canImport(AppKit)
import AppKit
import SwiftUI

// The hazard this file exists to close:
//
// `NSColor(someSwiftUIColor)` resolves an adaptive/dynamic `Color` against
// `NSAppearance.currentDrawing()`, which falls back to the *app's* effective
// appearance when called outside an active draw pass. It does **not** use the
// appearance of any particular window or view.
//
// Every theme color is adaptive (`CodexColorPair` → `Color.codexAdaptivePair`).
// So any code that converts one to `NSColor` from inside SwiftUI's
// `updateNSView`, a hover-state rebuild, or a cache warm-up — none of which are
// draw passes — silently freezes to whatever appearance happened to be current
// at that moment, which can disagree with the window it is drawn into. A window
// pinned to Light under a Dark system, or simply unlucky timing during a
// SwiftUI update pass, produces a permanently wrong-appearance layer color:
// a solid near-black row in an otherwise light sidebar, for example.
//
// The fix is not "pick the right ColorScheme and hope" — it is to resolve
// inside `NSAppearance.performAsCurrentDrawingAppearance`, which is the only
// API that pins a dynamic color's resolution to a specific appearance
// regardless of when or where it runs.
public enum CodexAppKitColor {
    /// Flattens a SwiftUI `Color` to a static sRGB `NSColor` under `appearance`.
    /// Pass `nil` only for a color that is known not to be theme-adaptive.
    @MainActor
    public static func resolve(_ color: Color, for appearance: NSAppearance?) -> NSColor {
        let dynamic = NSColor(color)
        guard let appearance else {
            return dynamic.usingColorSpace(.sRGB) ?? dynamic
        }
        var resolved = dynamic
        appearance.performAsCurrentDrawingAppearance {
            resolved = dynamic.usingColorSpace(.sRGB) ?? dynamic
        }
        return resolved
    }

    @MainActor
    public static func resolve(_ color: Color, for colorScheme: ColorScheme) -> NSColor {
        resolve(color, for: NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua))
    }
}

public extension NSAppearance {
    /// `appearance.codexResolve(someThemeColor)`. Reads better than the static
    /// form at call sites that already have a live `effectiveAppearance` —
    /// which is the case that matters most, because it tracks the *view's*
    /// actual appearance (including any per-window override) rather than a
    /// guessed `ColorScheme`.
    @MainActor
    func codexResolve(_ color: Color) -> NSColor {
        CodexAppKitColor.resolve(color, for: self)
    }
}
#endif
