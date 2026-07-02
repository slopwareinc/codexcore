import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@inline(__always)
private func codexHex(_ value: UInt32) -> Color {
    Color(
        red: Double((value >> 16) & 0xFF) / 255.0,
        green: Double((value >> 8) & 0xFF) / 255.0,
        blue: Double(value & 0xFF) / 255.0
    )
}

private extension Color {
    static func codexAdaptive(_ light: Color, _ dark: Color) -> Color {
        #if canImport(AppKit)
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
        #elseif canImport(UIKit)
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #else
        light
        #endif
    }
}

/// Shared design tokens for Codex chat UI components.
public struct CodexAgentTheme {
    public var colors: Colors
    public var fonts: Fonts
    public var spacing: Spacing
    public var radii: Radii
    public var effects: Effects
    public var animations: Animations

    public init(
        colors: Colors,
        fonts: Fonts = .official,
        spacing: Spacing = .official,
        radii: Radii = .official,
        effects: Effects = .official,
        animations: Animations = .official
    ) {
        self.colors = colors
        self.fonts = fonts
        self.spacing = spacing
        self.radii = radii
        self.effects = effects
        self.animations = animations
    }

    public struct Colors {
        public var canvas: Color
        public var surface: Color
        public var surfaceSunken: Color
        public var surfaceElevated: Color
        public var textPrimary: Color
        public var textSecondary: Color
        public var textTertiary: Color
        public var accent: Color
        public var accentSoft: Color
        public var onAccent: Color
        public var border: Color
        public var borderStrong: Color
        public var userBubble: Color
        public var userBubbleStroke: Color
        public var codeBackground: Color
        public var codeHeader: Color
        public var codeText: Color
        public var codeFaint: Color
        public var success: Color
        public var warning: Color
        public var danger: Color
        public var running: Color
        public var tool: Color

        public init(
            canvas: Color,
            surface: Color,
            surfaceSunken: Color,
            surfaceElevated: Color,
            textPrimary: Color,
            textSecondary: Color,
            textTertiary: Color,
            accent: Color,
            accentSoft: Color,
            onAccent: Color,
            border: Color,
            borderStrong: Color,
            userBubble: Color,
            userBubbleStroke: Color,
            codeBackground: Color,
            codeHeader: Color,
            codeText: Color,
            codeFaint: Color,
            success: Color,
            warning: Color,
            danger: Color,
            running: Color,
            tool: Color
        ) {
            self.canvas = canvas
            self.surface = surface
            self.surfaceSunken = surfaceSunken
            self.surfaceElevated = surfaceElevated
            self.textPrimary = textPrimary
            self.textSecondary = textSecondary
            self.textTertiary = textTertiary
            self.accent = accent
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
        }
    }

    public struct Fonts {
        public var body: Font
        public var chat: Font
        public var caption: Font
        public var label: Font
        public var code: Font
        public var micro: Font
        /// Optional platform font backing `chat`. When set, the prose
        /// cache bakes this font into each `AttributedString` run and
        /// applies `NSInlinePresentationIntent` (bold, italic, code)
        /// via `NSFontDescriptor.withSymbolicTraits`, resolving to
        /// the correct weight in the font family. When nil, the
        /// prose cache falls back to the system font.
        public var chatNSFont: NSFont?
        /// Optional platform font backing `code`. When set, inline code
        /// blocks inside prose will be styled using this font instead of
        /// the system monospaced font.
        public var codeNSFont: NSFont?

        public init(
            body: Font,
            chat: Font,
            caption: Font,
            label: Font,
            code: Font,
            micro: Font,
            chatNSFont: NSFont? = nil,
            codeNSFont: NSFont? = nil
        ) {
            self.body = body
            self.chat = chat
            self.caption = caption
            self.label = label
            self.code = code
            self.micro = micro
            self.chatNSFont = chatNSFont
            self.codeNSFont = codeNSFont
        }

        public static var official: Fonts {
            Fonts(
                body: .body,
                chat: .callout,
                caption: .caption,
                label: .subheadline.weight(.semibold),
                code: .system(.footnote, design: .monospaced),
                micro: .system(.caption2, design: .monospaced).weight(.semibold)
            )
        }
    }

    public struct Spacing {
        public var transcriptMaxWidth: CGFloat
        public var composerMaxWidth: CGFloat
        public var sidePanelWidth: CGFloat
        public var summaryPanelWidth: CGFloat
        public var toolbarHeight: CGFloat
        public var rowGap: CGFloat
        public var cardMaxWidth: CGFloat
        public var transcriptOuterMaxWidth: CGFloat
        public var userBubbleMaxWidth: CGFloat
        public var chipPadding: EdgeInsets
        public var iconSmall: CGFloat
        public var iconMedium: CGFloat
        public var iconLarge: CGFloat
        public var chatLineSpacing: CGFloat

        public init(
            transcriptMaxWidth: CGFloat,
            composerMaxWidth: CGFloat,
            sidePanelWidth: CGFloat,
            summaryPanelWidth: CGFloat,
            toolbarHeight: CGFloat,
            rowGap: CGFloat,
            cardMaxWidth: CGFloat,
            transcriptOuterMaxWidth: CGFloat,
            userBubbleMaxWidth: CGFloat,
            chipPadding: EdgeInsets = EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8),
            iconSmall: CGFloat = 13,
            iconMedium: CGFloat = 16,
            iconLarge: CGFloat = 28,
            chatLineSpacing: CGFloat = 4.8
        ) {
            self.transcriptMaxWidth = transcriptMaxWidth
            self.composerMaxWidth = composerMaxWidth
            self.sidePanelWidth = sidePanelWidth
            self.summaryPanelWidth = summaryPanelWidth
            self.toolbarHeight = toolbarHeight
            self.rowGap = rowGap
            self.cardMaxWidth = cardMaxWidth
            self.transcriptOuterMaxWidth = transcriptOuterMaxWidth
            self.userBubbleMaxWidth = userBubbleMaxWidth
            self.chipPadding = chipPadding
            self.iconSmall = iconSmall
            self.iconMedium = iconMedium
            self.iconLarge = iconLarge
            self.chatLineSpacing = chatLineSpacing
        }

        public static var official: Spacing {
            Spacing(
                transcriptMaxWidth: 736,
                composerMaxWidth: 736,
                sidePanelWidth: 320,
                summaryPanelWidth: 300,
                toolbarHeight: 46,
                rowGap: 12,
                cardMaxWidth: 640,
                transcriptOuterMaxWidth: 860,
                userBubbleMaxWidth: 560,
                chipPadding: EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
            )
        }
    }

    public struct Radii {
        public var small: CGFloat
        public var medium: CGFloat
        public var large: CGFloat
        public var panel: CGFloat
        public var composer: CGFloat
        public var bubble: CGFloat
        public var pill: CGFloat

        public init(
            small: CGFloat,
            medium: CGFloat,
            large: CGFloat,
            panel: CGFloat,
            composer: CGFloat,
            bubble: CGFloat,
            pill: CGFloat
        ) {
            self.small = small
            self.medium = medium
            self.large = large
            self.panel = panel
            self.composer = composer
            self.bubble = bubble
            self.pill = pill
        }

        public static var official: Radii {
            Radii(
                small: 6,
                medium: 12,
                large: 16,
                panel: 28,
                composer: 28,
                bubble: 16,
                pill: 999
            )
        }
    }

    public struct Effects {
        public var usesLiquidGlass: Bool
        public var surfaceOpacity: Double
        public var glowOpacity: Double
        public var glassOpacity: Double
        public var textFaintOpacity: Double
        public var textDimOpacity: Double

        public init(
            usesLiquidGlass: Bool,
            surfaceOpacity: Double,
            glowOpacity: Double,
            glassOpacity: Double = 0.72,
            textFaintOpacity: Double = 0.6,
            textDimOpacity: Double = 0.82
        ) {
            self.usesLiquidGlass = usesLiquidGlass
            self.surfaceOpacity = surfaceOpacity
            self.glowOpacity = glowOpacity
            self.glassOpacity = glassOpacity
            self.textFaintOpacity = textFaintOpacity
            self.textDimOpacity = textDimOpacity
        }

        public static var official: Effects {
            Effects(usesLiquidGlass: true, surfaceOpacity: 0.94, glowOpacity: 0.16)
        }
    }

    public struct Animations {
        public var defaultDuration: Double
        public var snappyDuration: Double
        public var springResponse: Double
        public var springDamping: Double

        public init(
            defaultDuration: Double = 0.15,
            snappyDuration: Double = 0.18,
            springResponse: Double = 0.32,
            springDamping: Double = 0.9
        ) {
            self.defaultDuration = defaultDuration
            self.snappyDuration = snappyDuration
            self.springResponse = springResponse
            self.springDamping = springDamping
        }

        public static var official: Animations { 
            Animations(
                defaultDuration: 0.25,
                snappyDuration: 0.2,
                springResponse: 0.4,
                springDamping: 0.85
            )
        }
    }
}

public extension CodexAgentTheme {
    static var officialDark: CodexAgentTheme {
        CodexAgentTheme(colors: .init(
            canvas: codexHex(0x0F0F0F),
            surface: codexHex(0x111111),
            surfaceSunken: codexHex(0x171717),
            surfaceElevated: codexHex(0x242424),
            textPrimary: codexHex(0xFCFCFC),
            textSecondary: codexHex(0xFCFCFC).opacity(0.65),
            textTertiary: codexHex(0xFCFCFC).opacity(0.47),
            accent: codexHex(0x7C84FF),
            accentSoft: codexHex(0x242844),
            onAccent: .white,
            border: codexHex(0xFCFCFC).opacity(0.075),
            borderStrong: codexHex(0xFCFCFC).opacity(0.16),
            userBubble: codexHex(0xFCFCFC).opacity(0.05),
            userBubbleStroke: codexHex(0xFCFCFC).opacity(0.075),
            codeBackground: codexHex(0x0C0E13),
            codeHeader: codexHex(0x15181F),
            codeText: codexHex(0xD6DBE4),
            codeFaint: codexHex(0x8A93A4),
            success: codexHex(0x44D17E),
            warning: codexHex(0xE7A23C),
            danger: codexHex(0xFF6B66),
            running: codexHex(0x5C9BFF),
            tool: codexHex(0xA78BFA)
        ), effects: .init(usesLiquidGlass: true, surfaceOpacity: 0.85, glowOpacity: 0.35))
    }

    static var nativeLight: CodexAgentTheme {
        CodexAgentTheme(colors: .init(
            canvas: codexHex(0xF5F6FA),
            surface: .white,
            surfaceSunken: codexHex(0xEEF0F5),
            surfaceElevated: codexHex(0xFFFFFF).opacity(0.96),
            textPrimary: codexHex(0x111318),
            textSecondary: codexHex(0x4E5562),
            textTertiary: codexHex(0x838A96),
            accent: codexHex(0x4F46E5),
            accentSoft: codexHex(0xE9E8FF),
            onAccent: .white,
            border: .black.opacity(0.08),
            borderStrong: .black.opacity(0.14),
            userBubble: codexHex(0xE9E8FF),
            userBubbleStroke: codexHex(0x4F46E5).opacity(0.16),
            codeBackground: codexHex(0x111827),
            codeHeader: codexHex(0x1F2937),
            codeText: codexHex(0xE5E7EB),
            codeFaint: codexHex(0x9CA3AF),
            success: codexHex(0x15803D),
            warning: codexHex(0xB45309),
            danger: codexHex(0xDC2626),
            running: codexHex(0x2563EB),
            tool: codexHex(0x7C3AED)
        ), effects: .init(usesLiquidGlass: true, surfaceOpacity: 0.88, glowOpacity: 0.10))
    }

    static var midnight: CodexAgentTheme {
        CodexAgentTheme(colors: .init(
            canvas: codexHex(0x070A12),
            surface: codexHex(0x0B1020),
            surfaceSunken: codexHex(0x0E1528),
            surfaceElevated: codexHex(0x18213A),
            textPrimary: codexHex(0xF4F7FF),
            textSecondary: codexHex(0xB4BED4),
            textTertiary: codexHex(0x707B94),
            accent: codexHex(0x6EE7F9),
            accentSoft: codexHex(0x12303A),
            onAccent: codexHex(0x071016),
            border: .white.opacity(0.08),
            borderStrong: .white.opacity(0.18),
            userBubble: codexHex(0x14223B),
            userBubbleStroke: codexHex(0x6EE7F9).opacity(0.16),
            codeBackground: codexHex(0x050814),
            codeHeader: codexHex(0x0D1426),
            codeText: codexHex(0xDBEAFE),
            codeFaint: codexHex(0x74819C),
            success: codexHex(0x34D399),
            warning: codexHex(0xFBBF24),
            danger: codexHex(0xFB7185),
            running: codexHex(0x38BDF8),
            tool: codexHex(0xC084FC)
        ), effects: .init(usesLiquidGlass: true, surfaceOpacity: 0.88, glowOpacity: 0.20))
    }

    static var warmMinimal: CodexAgentTheme {
        CodexAgentTheme(colors: .init(
            canvas: codexHex(0x171412),
            surface: codexHex(0x1D1916),
            surfaceSunken: codexHex(0x241F1B),
            surfaceElevated: codexHex(0x312A24),
            textPrimary: codexHex(0xFFF8EF),
            textSecondary: codexHex(0xD8C9B8),
            textTertiary: codexHex(0x9A8976),
            accent: codexHex(0xF4A261),
            accentSoft: codexHex(0x3B2B20),
            onAccent: codexHex(0x20130B),
            border: codexHex(0xFFF8EF).opacity(0.08),
            borderStrong: codexHex(0xFFF8EF).opacity(0.18),
            userBubble: codexHex(0x2A241F),
            userBubbleStroke: codexHex(0xF4A261).opacity(0.14),
            codeBackground: codexHex(0x120F0D),
            codeHeader: codexHex(0x201A16),
            codeText: codexHex(0xF8E8D5),
            codeFaint: codexHex(0x9A8976),
            success: codexHex(0x74C69D),
            warning: codexHex(0xF4A261),
            danger: codexHex(0xE76F51),
            running: codexHex(0x90CAF9),
            tool: codexHex(0xC4A7E7)
        ), effects: .init(usesLiquidGlass: true, surfaceOpacity: 0.90, glowOpacity: 0.12))
    }

    static var highContrast: CodexAgentTheme {
        CodexAgentTheme(colors: .init(
            canvas: .black,
            surface: .black,
            surfaceSunken: codexHex(0x101010),
            surfaceElevated: codexHex(0x1A1A1A),
            textPrimary: .white,
            textSecondary: .white.opacity(0.82),
            textTertiary: .white.opacity(0.64),
            accent: codexHex(0xFFD84D),
            accentSoft: codexHex(0x332A00),
            onAccent: .black,
            border: .white.opacity(0.22),
            borderStrong: .white.opacity(0.42),
            userBubble: .white.opacity(0.12),
            userBubbleStroke: .white.opacity(0.32),
            codeBackground: .black,
            codeHeader: codexHex(0x111111),
            codeText: .white,
            codeFaint: .white.opacity(0.72),
            success: codexHex(0x00FF8A),
            warning: codexHex(0xFFD84D),
            danger: codexHex(0xFF4D4D),
            running: codexHex(0x4DD2FF),
            tool: codexHex(0xD98CFF)
        ), effects: .init(usesLiquidGlass: false, surfaceOpacity: 1, glowOpacity: 0))
    }
}

private struct CodexAgentThemeKey: EnvironmentKey {
    static var defaultValue: CodexAgentTheme { .officialDark }
}

public extension EnvironmentValues {
    var codexAgentTheme: CodexAgentTheme {
        get { self[CodexAgentThemeKey.self] }
        set { self[CodexAgentThemeKey.self] = newValue }
    }
}

public extension View {
    func codexAgentTheme(_ theme: CodexAgentTheme) -> some View {
        environment(\.codexAgentTheme, theme)
    }
}

public enum CodexAgentThemePreset: String, CaseIterable, Identifiable, Sendable {
    case officialDark
    case nativeLight
    case midnight
    case warmMinimal
    case highContrast

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .officialDark: return "Official Dark"
        case .nativeLight: return "Native Light"
        case .midnight: return "Midnight"
        case .warmMinimal: return "Warm Minimal"
        case .highContrast: return "High Contrast"
        }
    }

    public var theme: CodexAgentTheme {
        switch self {
        case .officialDark: return .officialDark
        case .nativeLight: return .nativeLight
        case .midnight: return .midnight
        case .warmMinimal: return .warmMinimal
        case .highContrast: return .highContrast
        }
    }
}

@available(macOS 26.0, iOS 26.0, *)
private func makeCodexGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass: Glass = .regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}

public extension View {
    /// Applies native Liquid Glass when available, with a material fallback on older OS versions.
    @ViewBuilder
    func codexGlass<S: Shape>(
        _ shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(CodexGlassModifier(shape: shape, tint: tint, interactive: interactive))
    }
}

private struct CodexGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.codexAgentTheme) private var theme

    let shape: S
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        if theme.effects.usesLiquidGlass, #available(macOS 26.0, iOS 26.0, *) {
            content.glassEffect(makeCodexGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .background(theme.colors.surfaceElevated.opacity(theme.effects.surfaceOpacity), in: shape)
                .overlay(shape.stroke(theme.colors.border, lineWidth: 1))
        }
    }
}

/// A soft Codex chat backdrop that adapts to light and dark appearances.
public struct CodexBackdrop: View {
    @Environment(\.codexAgentTheme) private var theme

    public init() {}

    public var body: some View {
        ZStack {
            theme.colors.canvas
            RadialGradient(
                colors: [theme.colors.accent.opacity(theme.effects.glowOpacity), .clear],
                center: .topTrailing, startRadius: 1, endRadius: 720
            )
            RadialGradient(
                colors: [theme.colors.accent.opacity(theme.effects.glowOpacity * 0.5), .clear],
                center: .bottomLeading, startRadius: 1, endRadius: 640
            )
        }
        .ignoresSafeArea()
    }
}

/// Codex brand mark used by chat rows, empty states, and launch panels.
public struct CodexBrandMark: View {
    @Environment(\.codexAgentTheme) private var theme

    private let systemImage: String
    private let size: CGFloat

    public init(systemImage: String = "command", size: CGFloat = 36) {
        self.systemImage = systemImage
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [theme.colors.accent, theme.colors.accent.opacity(0.7)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            Image(systemName: systemImage)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: theme.colors.accent.opacity(0.32), radius: size * 0.32, y: size * 0.16)
    }
}
