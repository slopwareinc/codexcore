import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

// Theme palettes.
//
// Every color role is a *pair*: one value for light appearance, one for dark.
// A theme is therefore a hue family that works in both, not a single-appearance
// skin. Before this, four presets were dark-only and one was light-only, so
// choosing "Warm Sand" in a light environment handed you a dark window.
//
// Two rules make this safe:
//
//  1. `color` is an adaptive `Color`, resolved by the render server per view.
//     That is what SwiftUI wants.
//  2. `resolved(_:)` returns an opaque `Color` for a *known* appearance. AppKit
//     views must use this. Converting an adaptive SwiftUI `Color` to `NSColor`
//     resolves it against the process appearance rather than the window's, so
//     an AppKit-backed transcript would silently render the wrong palette.

/// A color in both appearances. Values are `0xRRGGBB`, or `0xAARRGGBB` when the
/// role needs alpha (borders, bubble fills, faint text).
public struct CodexColorPair: Equatable, Sendable, Hashable, Codable {
    public var light: UInt32
    public var dark: UInt32

    public init(light: UInt32, dark: UInt32) {
        self.light = light
        self.dark = dark
    }

    /// The same value in both appearances, for roles that genuinely do not vary.
    public init(_ both: UInt32) {
        self.light = both
        self.dark = both
    }

    public var color: Color {
        .codexAdaptivePair(self)
    }

    public func resolved(_ scheme: ColorScheme) -> Color {
        Self.decode(scheme == .dark ? dark : light)
    }

    public func value(for scheme: ColorScheme) -> UInt32 {
        scheme == .dark ? dark : light
    }

    /// Interprets `0xRRGGBB` as opaque and `0xAARRGGBB` as premultiplied-by-alpha
    /// notation. A bare RGB triple can never be mistaken for a transparent color
    /// because alpha 0 would make it invisible, which no palette role wants.
    static func decode(_ value: UInt32) -> Color {
        let alpha = (value >> 24) & 0xFF
        let opacity = value <= 0xFFFFFF ? 1.0 : Double(alpha) / 255.0
        return Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}

extension Color {
    /// An appearance-reactive color. Unlike a fixed `Color`, this resolves at
    /// draw time, so one palette serves both appearances.
    static func codexAdaptivePair(_ pair: CodexColorPair) -> Color {
        #if canImport(AppKit)
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(CodexColorPair.decode(isDark ? pair.dark : pair.light))
            }
        )
        #elseif canImport(UIKit)
        Color(
            uiColor: UIColor { traits in
                let isDark = traits.userInterfaceStyle == .dark
                return UIColor(CodexColorPair.decode(isDark ? pair.dark : pair.light))
            }
        )
        #else
        CodexColorPair.decode(pair.light)
        #endif
    }
}

/// A complete palette as light/dark pairs. `CodexAgentTheme.Colors` is built
/// from one of these.
public struct CodexPaletteSpec: Equatable, Sendable, Hashable, Codable {
    public var canvas: CodexColorPair
    public var surface: CodexColorPair
    public var surfaceSunken: CodexColorPair
    public var surfaceElevated: CodexColorPair
    public var textPrimary: CodexColorPair
    public var textSecondary: CodexColorPair
    public var textTertiary: CodexColorPair
    public var accent: CodexColorPair
    public var accentStrong: CodexColorPair
    public var accentText: CodexColorPair
    public var accentSoft: CodexColorPair
    public var onAccent: CodexColorPair
    public var border: CodexColorPair
    public var borderStrong: CodexColorPair
    public var userBubble: CodexColorPair
    public var userBubbleStroke: CodexColorPair
    public var codeBackground: CodexColorPair
    public var codeHeader: CodexColorPair
    public var codeText: CodexColorPair
    public var codeFaint: CodexColorPair
    public var success: CodexColorPair
    public var warning: CodexColorPair
    public var danger: CodexColorPair
    public var running: CodexColorPair
    public var tool: CodexColorPair
    public var codeKeyword: CodexColorPair
    public var codeString: CodexColorPair
    public var codeComment: CodexColorPair
    public var codeNumber: CodexColorPair
    public var scrim: CodexColorPair
    public var shadow: CodexColorPair
    public var hover: CodexColorPair
    public var selection: CodexColorPair

    public init(
        canvas: CodexColorPair,
        surface: CodexColorPair,
        surfaceSunken: CodexColorPair,
        surfaceElevated: CodexColorPair,
        textPrimary: CodexColorPair,
        textSecondary: CodexColorPair,
        textTertiary: CodexColorPair,
        accent: CodexColorPair,
        accentStrong: CodexColorPair,
        accentText: CodexColorPair,
        accentSoft: CodexColorPair,
        onAccent: CodexColorPair,
        border: CodexColorPair,
        borderStrong: CodexColorPair,
        userBubble: CodexColorPair,
        userBubbleStroke: CodexColorPair,
        codeBackground: CodexColorPair,
        codeHeader: CodexColorPair,
        codeText: CodexColorPair,
        codeFaint: CodexColorPair,
        success: CodexColorPair,
        warning: CodexColorPair,
        danger: CodexColorPair,
        running: CodexColorPair,
        tool: CodexColorPair,
        codeKeyword: CodexColorPair? = nil,
        codeString: CodexColorPair? = nil,
        codeComment: CodexColorPair? = nil,
        codeNumber: CodexColorPair? = nil,
        scrim: CodexColorPair? = nil,
        shadow: CodexColorPair? = nil,
        hover: CodexColorPair? = nil,
        selection: CodexColorPair? = nil
    ) {
        self.canvas = canvas
        self.surface = surface
        self.surfaceSunken = surfaceSunken
        self.surfaceElevated = surfaceElevated
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.accent = accent
        self.accentStrong = accentStrong
        self.accentText = accentText
        self.accentSoft = accentSoft
        self.onAccent = onAccent
        self.border = border
        self.borderStrong = borderStrong
        self.userBubble = userBubble
        self.userBubbleStroke = userBubbleStroke
        self.codeBackground = codeBackground
        self.codeHeader = codeHeader
        self.codeText = codeText
        self.codeFaint = codeFaint
        self.success = success
        self.warning = warning
        self.danger = danger
        self.running = running
        self.tool = tool
        self.codeKeyword = codeKeyword ?? accentText
        self.codeString = codeString ?? success
        self.codeComment = codeComment ?? codeFaint
        self.codeNumber = codeNumber ?? warning
        // A scrim dims toward the theme's own darkest neutral. A fixed black
        // punches a grey hole in a light window.
        self.scrim = scrim ?? CodexColorPair(light: 0x2A2A2E, dark: 0x000000)
        self.shadow = shadow ?? CodexColorPair(light: 0x1F2430, dark: 0x000000)
        self.hover = hover ?? textPrimary
        self.selection = selection ?? accent
    }
}

public extension CodexAgentTheme.Colors {
    /// Builds adaptive colors from a light/dark palette.
    init(spec: CodexPaletteSpec) {
        self.init(
            canvas: spec.canvas.color,
            surface: spec.surface.color,
            surfaceSunken: spec.surfaceSunken.color,
            surfaceElevated: spec.surfaceElevated.color,
            textPrimary: spec.textPrimary.color,
            textSecondary: spec.textSecondary.color,
            textTertiary: spec.textTertiary.color,
            accent: spec.accent.color,
            accentSoft: spec.accentSoft.color,
            onAccent: spec.onAccent.color,
            border: spec.border.color,
            borderStrong: spec.borderStrong.color,
            userBubble: spec.userBubble.color,
            userBubbleStroke: spec.userBubbleStroke.color,
            codeBackground: spec.codeBackground.color,
            codeHeader: spec.codeHeader.color,
            codeText: spec.codeText.color,
            codeFaint: spec.codeFaint.color,
            success: spec.success.color,
            warning: spec.warning.color,
            danger: spec.danger.color,
            running: spec.running.color,
            tool: spec.tool.color,
            codeKeyword: spec.codeKeyword.color,
            codeString: spec.codeString.color,
            codeComment: spec.codeComment.color,
            codeNumber: spec.codeNumber.color,
            scrim: spec.scrim.color,
            shadow: spec.shadow.color,
            hover: spec.hover.color,
            selection: spec.selection.color,
            accentStrong: spec.accentStrong.color,
            accentText: spec.accentText.color
        )
    }

    /// Opaque colors for one known appearance. AppKit-backed views must use this
    /// rather than converting the adaptive colors, which would resolve against
    /// the process appearance instead of the window's.
    init(spec: CodexPaletteSpec, resolvedFor scheme: ColorScheme) {
        self.init(
            canvas: spec.canvas.resolved(scheme),
            surface: spec.surface.resolved(scheme),
            surfaceSunken: spec.surfaceSunken.resolved(scheme),
            surfaceElevated: spec.surfaceElevated.resolved(scheme),
            textPrimary: spec.textPrimary.resolved(scheme),
            textSecondary: spec.textSecondary.resolved(scheme),
            textTertiary: spec.textTertiary.resolved(scheme),
            accent: spec.accent.resolved(scheme),
            accentSoft: spec.accentSoft.resolved(scheme),
            onAccent: spec.onAccent.resolved(scheme),
            border: spec.border.resolved(scheme),
            borderStrong: spec.borderStrong.resolved(scheme),
            userBubble: spec.userBubble.resolved(scheme),
            userBubbleStroke: spec.userBubbleStroke.resolved(scheme),
            codeBackground: spec.codeBackground.resolved(scheme),
            codeHeader: spec.codeHeader.resolved(scheme),
            codeText: spec.codeText.resolved(scheme),
            codeFaint: spec.codeFaint.resolved(scheme),
            success: spec.success.resolved(scheme),
            warning: spec.warning.resolved(scheme),
            danger: spec.danger.resolved(scheme),
            running: spec.running.resolved(scheme),
            tool: spec.tool.resolved(scheme),
            codeKeyword: spec.codeKeyword.resolved(scheme),
            codeString: spec.codeString.resolved(scheme),
            codeComment: spec.codeComment.resolved(scheme),
            codeNumber: spec.codeNumber.resolved(scheme),
            scrim: spec.scrim.resolved(scheme),
            shadow: spec.shadow.resolved(scheme),
            hover: spec.hover.resolved(scheme),
            selection: spec.selection.resolved(scheme),
            accentStrong: spec.accentStrong.resolved(scheme),
            accentText: spec.accentText.resolved(scheme)
        )
    }
}
