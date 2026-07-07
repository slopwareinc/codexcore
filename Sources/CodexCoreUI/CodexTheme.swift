import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@inline(__always)
private func codexHex(_ value: UInt32) -> Color {
    Color.codexHex(value)
}

private extension Color {
    static func codexHex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}

public struct CodexThemeColorValue: Codable, Equatable, Sendable, Identifiable {
    public var id: UInt32 { rawValue }
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue & 0xFFFFFF
    }

    public init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespacesAndNewlines))
        self.rawValue = UInt32(trimmed, radix: 16).map { $0 & 0xFFFFFF } ?? 0
    }

    public var color: Color {
        .codexHex(rawValue)
    }

    public var hexString: String {
        String(format: "#%06X", rawValue)
    }
}

public enum CodexDiffMarkerStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case color
    case signs

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .color: return "Color"
        case .signs: return "+/-"
        }
    }
}

public enum CodexDockIconVariant: String, CaseIterable, Codable, Identifiable, Sendable {
    case `default`
    case codexLight
    case codexDark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .default: return "Default"
        case .codexLight: return "Codex Light"
        case .codexDark: return "Codex Dark"
        }
    }
}

public struct CodexAppearanceSettings: Codable, Equatable, Sendable {
    public static let uiFontSizeRange: ClosedRange<Double> = 11...18

    public var preset: CodexAgentThemePreset
    public var reduceMotion: Bool
    public var uiFontSize: Double
    public var diffMarkerStyle: CodexDiffMarkerStyle
    public var dockIconVariant: CodexDockIconVariant

    public init(
        preset: CodexAgentThemePreset = .officialDark,
        reduceMotion: Bool = false,
        uiFontSize: Double = 14,
        diffMarkerStyle: CodexDiffMarkerStyle = .color,
        dockIconVariant: CodexDockIconVariant = .default
    ) {
        self.preset = preset
        self.reduceMotion = reduceMotion
        self.uiFontSize = min(max(uiFontSize, Self.uiFontSizeRange.lowerBound), Self.uiFontSizeRange.upperBound)
        self.diffMarkerStyle = diffMarkerStyle
        self.dockIconVariant = dockIconVariant
    }

    public static var official: CodexAppearanceSettings {
        CodexAppearanceSettings()
    }

    public func agentTheme(uiFontSize: Double, reduceMotion: Bool) -> CodexAgentTheme {
        let base = preset.theme
        var theme = base
        theme.fonts = .official.scaled(baseTextSize: uiFontSize)
        theme.animations = reduceMotion ? .reduced : .official
        return theme
    }
}

private extension CodexAgentTheme.Fonts {
    func scaled(baseTextSize: Double) -> CodexAgentTheme.Fonts {
        let bodySize = CGFloat(min(max(baseTextSize, CodexAppearanceSettings.uiFontSizeRange.lowerBound), CodexAppearanceSettings.uiFontSizeRange.upperBound))
        return CodexAgentTheme.Fonts(
            body: .system(size: bodySize),
            chat: .system(size: bodySize + 1),
            caption: .system(size: max(9, bodySize - 2)),
            label: .system(size: max(10, bodySize - 1), weight: .semibold),
            code: .system(size: max(10, bodySize - 1), design: .monospaced),
            micro: .system(size: max(8, bodySize - 3), weight: .semibold, design: .monospaced),
            sidebar: sidebar,
            chatNSFont: chatNSFont,
            codeNSFont: codeNSFont
        )
    }
}

extension CodexAgentTheme.Animations {
    public static var reduced: CodexAgentTheme.Animations {
        CodexAgentTheme.Animations(defaultDuration: 0.01, snappyDuration: 0.01, springResponse: 0.01, springDamping: 1)
    }
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

    public enum FontWeightToken: String, CaseIterable, Codable {
        case regular
        case medium
        case semibold
        case bold

        var fontWeight: Font.Weight {
            switch self {
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            }
        }
    }

    public enum FontDesignToken: String, CaseIterable, Codable {
        case system
        case rounded
        case serif
        case monospaced

        var fontDesign: Font.Design? {
            switch self {
            case .system: return nil
            case .rounded: return .rounded
            case .serif: return .serif
            case .monospaced: return .monospaced
            }
        }
    }

    public struct FontToken: Codable, Equatable {
        public var size: CGFloat
        public var weight: FontWeightToken
        public var design: FontDesignToken

        public init(size: CGFloat, weight: FontWeightToken = .regular, design: FontDesignToken = .system) {
            self.size = size
            self.weight = weight
            self.design = design
        }

        public var font: Font {
            if let fontDesign = design.fontDesign {
                return .system(size: size, weight: weight.fontWeight, design: fontDesign)
            }
            return .system(size: size, weight: weight.fontWeight)
        }
    }

    public struct Fonts {
        public var body: Font
        public var chat: Font
        public var caption: Font
        public var label: Font
        public var code: Font
        public var micro: Font
        public var sidebar: SidebarTypography
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
            sidebar: SidebarTypography = .official,
            chatNSFont: NSFont? = nil,
            codeNSFont: NSFont? = nil
        ) {
            self.body = body
            self.chat = chat
            self.caption = caption
            self.label = label
            self.code = code
            self.micro = micro
            self.sidebar = sidebar
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

        public struct SidebarTypography: Codable, Equatable {
            public static let defaultBaseTextSize: Double = 12
            public static let baseTextSizeRange: ClosedRange<Double> = 11...18

            public var titlebarIcon: FontToken
            public var accountInitialsCollapsed: FontToken
            public var accountInitialsExpanded: FontToken
            public var accountName: FontToken
            public var accountDetail: FontToken
            public var accountDeviceIcon: FontToken
            public var commandIcon: FontToken
            public var commandTitle: FontToken
            public var commandShortcut: FontToken
            public var sectionHeader: FontToken
            public var disclosureChevron: FontToken
            public var disclosureTitle: FontToken
            public var disclosureCount: FontToken
            public var projectIcon: FontToken
            public var projectTitle: FontToken
            public var emptyState: FontToken
            public var hiddenRowsPrompt: FontToken
            public var chatTitle: FontToken
            public var chatRecency: FontToken
            public var chatActionIcon: FontToken

            public init(
                titlebarIcon: FontToken,
                accountInitialsCollapsed: FontToken,
                accountInitialsExpanded: FontToken,
                accountName: FontToken,
                accountDetail: FontToken,
                accountDeviceIcon: FontToken,
                commandIcon: FontToken,
                commandTitle: FontToken,
                commandShortcut: FontToken,
                sectionHeader: FontToken,
                disclosureChevron: FontToken,
                disclosureTitle: FontToken,
                disclosureCount: FontToken,
                projectIcon: FontToken,
                projectTitle: FontToken,
                emptyState: FontToken,
                hiddenRowsPrompt: FontToken,
                chatTitle: FontToken,
                chatRecency: FontToken,
                chatActionIcon: FontToken
            ) {
                self.titlebarIcon = titlebarIcon
                self.accountInitialsCollapsed = accountInitialsCollapsed
                self.accountInitialsExpanded = accountInitialsExpanded
                self.accountName = accountName
                self.accountDetail = accountDetail
                self.accountDeviceIcon = accountDeviceIcon
                self.commandIcon = commandIcon
                self.commandTitle = commandTitle
                self.commandShortcut = commandShortcut
                self.sectionHeader = sectionHeader
                self.disclosureChevron = disclosureChevron
                self.disclosureTitle = disclosureTitle
                self.disclosureCount = disclosureCount
                self.projectIcon = projectIcon
                self.projectTitle = projectTitle
                self.emptyState = emptyState
                self.hiddenRowsPrompt = hiddenRowsPrompt
                self.chatTitle = chatTitle
                self.chatRecency = chatRecency
                self.chatActionIcon = chatActionIcon
            }

            public func accountInitials(isCollapsed: Bool) -> Font {
                (isCollapsed ? accountInitialsCollapsed : accountInitialsExpanded).font
            }

            public var commandRowHeight: CGFloat {
                rowHeight(for: commandTitle, padding: 20)
            }

            public var projectRowHeight: CGFloat {
                rowHeight(for: projectTitle, padding: 19)
            }

            public var collapsedProjectRowHeight: CGFloat {
                rowHeight(for: projectTitle, padding: 17)
            }

            public var chatRowHeight: CGFloat {
                rowHeight(for: chatTitle, padding: 18)
            }

            public var sectionHeaderHeight: CGFloat {
                rowHeight(for: sectionHeader, padding: 16)
            }

            public var disclosureRowHeight: CGFloat {
                rowHeight(for: disclosureTitle, padding: 18)
            }

            public var hiddenRowsPromptHeight: CGFloat {
                rowHeight(for: hiddenRowsPrompt, padding: 17)
            }

            public var accountFooterHeight: CGFloat {
                max(44, accountName.size + accountDetail.size + 24)
            }

            public var collapsedAccountFooterHeight: CGFloat {
                max(38, accountInitialsCollapsed.size + 30)
            }

            private func rowHeight(for token: FontToken, padding: CGFloat) -> CGFloat {
                max(24, token.size + padding)
            }

            public static var official: SidebarTypography {
                official(baseTextSize: defaultBaseTextSize)
            }

            public static func official(baseTextSize requestedSize: Double) -> SidebarTypography {
                let baseTextSize = min(max(requestedSize, baseTextSizeRange.lowerBound), baseTextSizeRange.upperBound)

                func token(_ offset: Double, weight: FontWeightToken = .regular) -> FontToken {
                    FontToken(size: CGFloat(max(8, baseTextSize + offset)), weight: weight)
                }

                return SidebarTypography(
                    titlebarIcon: token(1, weight: .medium),
                    accountInitialsCollapsed: token(-3, weight: .medium),
                    accountInitialsExpanded: token(-1, weight: .medium),
                    accountName: token(-1, weight: .semibold),
                    accountDetail: token(-3),
                    accountDeviceIcon: token(1),
                    commandIcon: token(1),
                    commandTitle: token(0, weight: .medium),
                    commandShortcut: token(-3),
                    sectionHeader: token(-2, weight: .medium),
                    disclosureChevron: token(-4, weight: .semibold),
                    disclosureTitle: token(-1, weight: .medium),
                    disclosureCount: token(-3),
                    projectIcon: token(1),
                    projectTitle: token(0, weight: .medium),
                    emptyState: token(-3),
                    hiddenRowsPrompt: token(-1, weight: .medium),
                    chatTitle: token(0, weight: .medium),
                    chatRecency: token(-3),
                    chatActionIcon: FontToken(size: CGFloat(max(8, baseTextSize - 5.5)), weight: .semibold)
                )
            }
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
            textSecondary: codexHex(0xFCFCFC).opacity(0.68),
            textTertiary: codexHex(0xFCFCFC).opacity(0.55),
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

public enum CodexAgentThemePreset: String, CaseIterable, Codable, Identifiable, Sendable {
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
                .foregroundStyle(theme.colors.onAccent)
        }
        .frame(width: size, height: size)
        .shadow(color: theme.colors.accent.opacity(0.32), radius: size * 0.32, y: size * 0.16)
    }
}
