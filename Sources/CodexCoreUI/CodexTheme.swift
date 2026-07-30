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
    /// Whether to follow the system appearance or pin light/dark. Themes render
    /// in both, so this is independent of the preset.
    public var appearanceMode: CodexAppearanceMode
    public var reduceMotion: Bool
    public var uiFontSize: Double
    public var diffMarkerStyle: CodexDiffMarkerStyle
    public var dockIconVariant: CodexDockIconVariant
    /// Family name for interface/prose text. `nil` = system (San Francisco).
    public var textFontFamily: String?
    /// Family name for monospaced contexts (code, diffs). `nil` = system mono.
    public var monoFontFamily: String?

    public init(
        preset: CodexAgentThemePreset = .officialDark,
        appearanceMode: CodexAppearanceMode? = nil,
        reduceMotion: Bool = false,
        uiFontSize: Double = 14,
        diffMarkerStyle: CodexDiffMarkerStyle = .color,
        dockIconVariant: CodexDockIconVariant = .default,
        textFontFamily: String? = nil,
        monoFontFamily: String? = nil
    ) {
        self.preset = preset
        // Absent an explicit choice, honor the appearance the preset's name used
        // to imply, so an existing "Official Dark" install stays dark.
        self.appearanceMode = appearanceMode ?? preset.impliedAppearance
        self.reduceMotion = reduceMotion
        self.uiFontSize = min(max(uiFontSize, Self.uiFontSizeRange.lowerBound), Self.uiFontSizeRange.upperBound)
        self.diffMarkerStyle = diffMarkerStyle
        self.dockIconVariant = dockIconVariant
        self.textFontFamily = textFontFamily?.nilIfBlank
        self.monoFontFamily = monoFontFamily?.nilIfBlank
    }

    /// Decodes key by key. The synthesized decoder does not apply property
    /// defaults for absent keys, so adding any field would have failed the whole
    /// decode and silently reset every stored appearance preference.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let preset = try container.decodeIfPresent(CodexAgentThemePreset.self, forKey: .preset) ?? .officialDark
        self.init(
            preset: preset,
            appearanceMode: try container.decodeIfPresent(CodexAppearanceMode.self, forKey: .appearanceMode),
            reduceMotion: try container.decodeIfPresent(Bool.self, forKey: .reduceMotion) ?? false,
            uiFontSize: try container.decodeIfPresent(Double.self, forKey: .uiFontSize) ?? 14,
            diffMarkerStyle: try container.decodeIfPresent(CodexDiffMarkerStyle.self, forKey: .diffMarkerStyle) ?? .color,
            dockIconVariant: try container.decodeIfPresent(CodexDockIconVariant.self, forKey: .dockIconVariant) ?? .default,
            textFontFamily: try container.decodeIfPresent(String.self, forKey: .textFontFamily),
            monoFontFamily: try container.decodeIfPresent(String.self, forKey: .monoFontFamily)
        )
    }

    public static var official: CodexAppearanceSettings {
        CodexAppearanceSettings()
    }

    public func agentTheme(uiFontSize: Double, reduceMotion: Bool) -> CodexAgentTheme {
        var theme = preset.theme
        theme.fonts = .official.scaled(
            baseTextSize: uiFontSize,
            textFamily: textFontFamily,
            monoFamily: monoFontFamily
        )
        theme.animations = reduceMotion ? .reduced : .official
        return theme
    }

    /// The theme with colors resolved for a known appearance, for AppKit-backed
    /// views that must not resolve adaptive colors themselves.
    public func agentTheme(
        uiFontSize: Double,
        reduceMotion: Bool,
        resolvedFor scheme: ColorScheme
    ) -> CodexAgentTheme {
        var theme = agentTheme(uiFontSize: uiFontSize, reduceMotion: reduceMotion)
        theme.colors = CodexAgentTheme.Colors(spec: preset.palette, resolvedFor: scheme)
        return theme
    }
}

/// Resolves an optional font-family name into SwiftUI `Font` + backing `NSFont`
/// tokens, falling back to the system font when the family is nil or missing so
/// the UI never renders in a broken/unavailable typeface.
struct CodexFontFamily {
    let family: String?
    let monospaced: Bool

    static func text(_ family: String?) -> CodexFontFamily { .init(family: family, monospaced: false) }
    static func mono(_ family: String?) -> CodexFontFamily { .init(family: family, monospaced: true) }

    func nsFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont? {
        guard let family, !family.isEmpty else { return nil }
        var attributes: [NSFontDescriptor.AttributeName: Any] = [.family: family]
        attributes[.traits] = [NSFontDescriptor.TraitKey.weight: weight.rawValue]
        let descriptor = NSFontDescriptor(fontAttributes: attributes)
        return NSFont(descriptor: descriptor, size: size)
    }

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let nsFont = nsFont(size: size, weight: weight.nsFontWeight) {
            return Font(nsFont)
        }
        return .system(size: size, weight: weight, design: monospaced ? .monospaced : .default)
    }
}

private extension Font.Weight {
    var nsFontWeight: NSFont.Weight {
        switch self {
        case .semibold: return .semibold
        case .bold: return .bold
        case .medium: return .medium
        case .light: return .light
        default: return .regular
        }
    }
}

/// Catalog of installed font families for the settings pickers. Computed once
/// from the system; the curated lists are the safe, good-looking built-ins.
public enum CodexSystemFonts {
    /// Menu label for the "use the system font" choice (a nil family).
    public static let systemLabel = "System"

    /// All installed families, excluding hidden system fonts (dot-prefixed).
    public static let allTextFamilies: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    /// Fixed-pitch families only, for the monospace picker.
    public static let monospacedFamilies: [String] = allTextFamilies.filter(isFixedPitch)

    /// Hand-picked interface fonts that ship with macOS and have full weights.
    public static let curatedText: [String] = intersecting(["New York", "Helvetica Neue", "Avenir Next", "Georgia", "Palatino"])

    /// Hand-picked monospace fonts that ship with macOS.
    public static let curatedMono: [String] = intersecting(["SF Mono", "Menlo", "Monaco", "Courier New"])

    public static func isFixedPitch(_ family: String) -> Bool {
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
        return NSFont(descriptor: descriptor, size: 12)?.isFixedPitch ?? false
    }

    private static func intersecting(_ names: [String]) -> [String] {
        let available = Set(allTextFamilies)
        return names.filter(available.contains)
    }
}

private extension CodexAgentTheme.Fonts {
    func scaled(baseTextSize: Double, textFamily: String?, monoFamily: String?) -> CodexAgentTheme.Fonts {
        let bodySize = CGFloat(min(max(baseTextSize, CodexAppearanceSettings.uiFontSizeRange.lowerBound), CodexAppearanceSettings.uiFontSizeRange.upperBound))
        let text = CodexFontFamily.text(textFamily)
        let mono = CodexFontFamily.mono(monoFamily)
        let chatSize = bodySize + 1
        let codeSize = max(10, bodySize - 1)
        return CodexAgentTheme.Fonts(
            body: text.font(size: bodySize),
            chat: text.font(size: chatSize),
            caption: text.font(size: max(9, bodySize - 2)),
            label: text.font(size: max(10, bodySize - 1), weight: .semibold),
            code: mono.font(size: codeSize),
            micro: mono.font(size: max(8, bodySize - 3), weight: .semibold),
            // Headings resolve in the user's chosen text family too, at the same
            // offsets as `Fonts.official(baseTextSize:)`.
            routeTitle: text.font(size: bodySize + 5, weight: .semibold),
            sheetTitle: text.font(size: bodySize + 3, weight: .semibold),
            panelTitle: text.font(size: bodySize + 1, weight: .semibold),
            panelLabel: text.font(size: max(10, bodySize - 1), weight: .semibold),
            heroTitle: text.font(size: bodySize + 8, weight: .semibold),
            actionIcon: text.font(size: bodySize + 2, weight: .medium),
            chipLabel: text.font(size: max(9, bodySize - 2), weight: .medium),
            sidebar: sidebar,
            // Backing NSFonts drive prose/code markdown styling. Stay nil for the
            // system font (the prose views fall back to `fonts.chat`), and carry
            // the resolved family + scaled size for a custom pick.
            chatNSFont: text.nsFont(size: chatSize),
            codeNSFont: mono.nsFont(size: codeSize)
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
        public var codeKeyword: Color
        public var codeString: Color
        public var codeComment: Color
        public var codeNumber: Color
        /// Dimming behind modal surfaces. Applied at `Effects.scrimOpacity`.
        public var scrim: Color
        /// Base color for every drop shadow. Derived from the theme so shadows
        /// stay visible on dark canvases, where a fixed black vanishes.
        public var shadow: Color
        /// Pointer-hover and press emphasis, applied at the matching
        /// `Effects.hoverOpacity` / `pressedOpacity`.
        public var hover: Color
        /// Selected-row emphasis, applied at `Effects.selectionOpacity`.
        public var selection: Color
        /// A deeper accent for pressed and active accent states.
        public var accentStrong: Color
        /// An accent legible as *text on the page*, which the fill accent often
        /// is not. Keeping this separate is what lets a pastel or dark accent
        /// theme stay readable.
        public var accentText: Color

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
            tool: Color,
            codeKeyword: Color? = nil,
            codeString: Color? = nil,
            codeComment: Color? = nil,
            codeNumber: Color? = nil,
            scrim: Color? = nil,
            shadow: Color? = nil,
            hover: Color? = nil,
            selection: Color? = nil,
            accentStrong: Color? = nil,
            accentText: Color? = nil
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
            self.codeKeyword = codeKeyword ?? accent
            self.codeString = codeString ?? success
            self.codeComment = codeComment ?? codeFaint
            self.codeNumber = codeNumber ?? warning
            // Scrims and shadows key off the canvas rather than a fixed black,
            // so a light theme dims toward its own darkest neutral instead of
            // punching a grey hole in the window.
            self.scrim = scrim ?? .black
            self.shadow = shadow ?? .black
            self.hover = hover ?? textPrimary
            self.selection = selection ?? accent
            self.accentStrong = accentStrong ?? accent
            self.accentText = accentText ?? accent
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
        /// Page and route headings. One token, where the app previously used
        /// three sizes (18, 22, 24) for the same role.
        public var routeTitle: Font
        /// Sheet, overlay, and popover headings.
        public var sheetTitle: Font
        /// Headings inside a panel or card.
        public var panelTitle: Font
        /// Small section labels inside a panel.
        public var panelLabel: Font
        /// Empty states and onboarding headlines. Deliberately the largest token
        /// in the app, and deliberately much smaller than a marketing headline:
        /// this is chrome, not a landing page.
        public var heroTitle: Font
        /// Toolbar and action glyphs. Replaces `.title2` and friends, which
        /// ignore the user's interface font size.
        public var actionIcon: Font
        /// Inline chips and pills.
        public var chipLabel: Font
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
            routeTitle: Font? = nil,
            sheetTitle: Font? = nil,
            panelTitle: Font? = nil,
            panelLabel: Font? = nil,
            heroTitle: Font? = nil,
            actionIcon: Font? = nil,
            chipLabel: Font? = nil,
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
            // The heading tokens fall back to the nearest generic token rather
            // than to a fixed point size, so a caller that supplies only the
            // base six still gets a coherent scale.
            self.routeTitle = routeTitle ?? label
            self.sheetTitle = sheetTitle ?? label
            self.panelTitle = panelTitle ?? label
            self.panelLabel = panelLabel ?? label
            self.heroTitle = heroTitle ?? label
            self.actionIcon = actionIcon ?? body
            self.chipLabel = chipLabel ?? caption
            self.sidebar = sidebar
            self.chatNSFont = chatNSFont
            self.codeNSFont = codeNSFont
        }

        public static var official: Fonts {
            .official(baseTextSize: SidebarTypography.defaultBaseTextSize)
        }

        /// The full scale at a given interface font size. Offsets are relative to
        /// the base so every token tracks the user's slider; only the sidebar did
        /// before.
        public static func official(baseTextSize requestedSize: Double) -> Fonts {
            let base = CGFloat(
                min(
                    max(requestedSize, CodexAppearanceSettings.uiFontSizeRange.lowerBound),
                    CodexAppearanceSettings.uiFontSizeRange.upperBound
                )
            )
            return Fonts(
                body: .system(size: base),
                chat: .system(size: base + 1),
                caption: .system(size: max(9, base - 2)),
                label: .system(size: max(10, base - 1), weight: .semibold),
                code: .system(size: max(10, base - 1), design: .monospaced),
                micro: .system(size: max(8, base - 3), design: .monospaced).weight(.semibold),
                routeTitle: .system(size: base + 5, weight: .semibold),
                sheetTitle: .system(size: base + 3, weight: .semibold),
                panelTitle: .system(size: base + 1, weight: .semibold),
                panelLabel: .system(size: max(10, base - 1), weight: .semibold),
                heroTitle: .system(size: base + 8, weight: .semibold),
                actionIcon: .system(size: base + 2, weight: .medium),
                chipLabel: .system(size: max(9, base - 2), weight: .medium),
                sidebar: .official(baseTextSize: requestedSize)
            )
        }

        public struct SidebarTypography: Codable, Equatable {
            public static let defaultBaseTextSize: Double = 14
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
                rowHeight(for: commandTitle, padding: 17)
            }

            public var projectRowHeight: CGFloat {
                rowHeight(for: projectTitle, padding: 17)
            }

            public var collapsedProjectRowHeight: CGFloat {
                rowHeight(for: projectTitle, padding: 16)
            }

            public var chatRowHeight: CGFloat {
                rowHeight(for: chatTitle, padding: 17)
            }

            public var sectionHeaderHeight: CGFloat {
                rowHeight(for: sectionHeader, padding: 14)
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
                    titlebarIcon: token(-1, weight: .medium),
                    accountInitialsCollapsed: token(-3, weight: .medium),
                    accountInitialsExpanded: token(-1, weight: .medium),
                    accountName: token(-1, weight: .semibold),
                    accountDetail: token(-3),
                    accountDeviceIcon: token(-1),
                    commandIcon: token(-1),
                    commandTitle: token(0),
                    commandShortcut: token(-3),
                    sectionHeader: token(-2, weight: .medium),
                    disclosureChevron: token(-6, weight: .semibold),
                    disclosureTitle: token(-1, weight: .medium),
                    disclosureCount: token(-3),
                    projectIcon: token(-1),
                    projectTitle: token(0),
                    emptyState: token(-3),
                    hiddenRowsPrompt: token(-1, weight: .medium),
                    chatTitle: token(0),
                    chatRecency: token(-3),
                    chatActionIcon: FontToken(size: CGFloat(max(8, baseTextSize - 7.5)), weight: .semibold)
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

        // A spacing ramp. `Spacing` previously held only widths, icon sizes and
        // a line height, so padding was picked per view: the app used every
        // value from 2 to 34 as a raw literal.
        public var xxs: CGFloat
        public var xs: CGFloat
        public var sm: CGFloat
        public var md: CGFloat
        public var lg: CGFloat
        public var xl: CGFloat
        public var xxl: CGFloat
        /// Inset inside a panel or card.
        public var panelPadding: CGFloat
        /// Inset inside a sheet or modal.
        public var sheetPadding: CGFloat
        /// Horizontal inset of a list row.
        public var rowPadding: CGFloat
        /// Gap between titled sections.
        public var sectionGap: CGFloat

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
            chatLineSpacing: CGFloat = 4.8,
            xxs: CGFloat = 2,
            xs: CGFloat = 4,
            sm: CGFloat = 8,
            md: CGFloat = 12,
            lg: CGFloat = 16,
            xl: CGFloat = 24,
            xxl: CGFloat = 32,
            panelPadding: CGFloat = 14,
            sheetPadding: CGFloat = 20,
            rowPadding: CGFloat = 10,
            sectionGap: CGFloat = 18
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
            self.xxs = xxs
            self.xs = xs
            self.sm = sm
            self.md = md
            self.lg = lg
            self.xl = xl
            self.xxl = xxl
            self.panelPadding = panelPadding
            self.sheetPadding = sheetPadding
            self.rowPadding = rowPadding
            self.sectionGap = sectionGap
        }

        public static var official: Spacing {
            Spacing(
                transcriptMaxWidth: 736,
                composerMaxWidth: 736,
                sidePanelWidth: 400,
                summaryPanelWidth: 328,
                toolbarHeight: 46,
                rowGap: 12,
                cardMaxWidth: 640,
                // Matches the composer's 736pt content width plus its 16pt
                // framing allowance on each side, so both columns align.
                transcriptOuterMaxWidth: 768,
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
        /// One shadow recipe for the whole app. Replaces the five hand-rolled
        /// `.black.opacity(...)` variants that were scattered across panels and
        /// overlays; a fixed black shadow disappears against a dark canvas, so
        /// the color is derived from the theme instead.
        public struct Shadow: Equatable, Sendable {
            public var opacity: Double
            public var radius: CGFloat
            public var y: CGFloat

            public init(opacity: Double, radius: CGFloat, y: CGFloat) {
                self.opacity = opacity
                self.radius = radius
                self.y = y
            }

            public func color(for theme: CodexAgentTheme) -> Color {
                theme.colors.shadow.opacity(opacity)
            }

            public static var panel: Shadow { Shadow(opacity: 0.28, radius: 20, y: 12) }
            public static var card: Shadow { Shadow(opacity: 0.16, radius: 12, y: 4) }
        }

        public var usesLiquidGlass: Bool
        public var surfaceOpacity: Double
        public var glowOpacity: Double
        public var glassOpacity: Double
        public var textFaintOpacity: Double
        public var textDimOpacity: Double
        /// Shadow used by floating surfaces, and by the opaque glass fallback to
        /// stand in for the shadow real glass draws for itself.
        public var shadow: Shadow
        /// Dimming behind a modal surface.
        public var scrimOpacity: Double
        /// How far a tint pulls the opaque glass fallback toward the tint color.
        public var tintStrength: Double
        /// Pointer-hover emphasis on rows and controls.
        public var hoverOpacity: Double
        /// Press emphasis.
        public var pressedOpacity: Double
        /// Selected-row emphasis.
        public var selectionOpacity: Double

        public init(
            usesLiquidGlass: Bool,
            surfaceOpacity: Double,
            glowOpacity: Double,
            glassOpacity: Double = 0.72,
            textFaintOpacity: Double = 0.6,
            textDimOpacity: Double = 0.82,
            shadow: Shadow = .panel,
            scrimOpacity: Double = 0.38,
            tintStrength: Double = 0.18,
            hoverOpacity: Double = 0.08,
            pressedOpacity: Double = 0.14,
            selectionOpacity: Double = 0.20
        ) {
            self.usesLiquidGlass = usesLiquidGlass
            self.surfaceOpacity = surfaceOpacity
            self.glowOpacity = glowOpacity
            self.glassOpacity = glassOpacity
            self.textFaintOpacity = textFaintOpacity
            self.textDimOpacity = textDimOpacity
            self.shadow = shadow
            self.scrimOpacity = scrimOpacity
            self.tintStrength = tintStrength
            self.hoverOpacity = hoverOpacity
            self.pressedOpacity = pressedOpacity
            self.selectionOpacity = selectionOpacity
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
    /// The default theme. Kept as a name because it is the environment default
    /// and is referenced widely, including by tests.
    static var officialDark: CodexAgentTheme { CodexAgentThemePreset.officialDark.theme }
    static var nativeLight: CodexAgentTheme { CodexAgentThemePreset.nativeLight.theme }
    static var midnight: CodexAgentTheme { CodexAgentThemePreset.midnight.theme }
    static var warmMinimal: CodexAgentTheme { CodexAgentThemePreset.warmMinimal.theme }
    static var highContrast: CodexAgentTheme { CodexAgentThemePreset.highContrast.theme }
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

/// The built-in theme families. Each renders in both light and dark, so the
/// preset chooses character and `CodexAppearanceMode` chooses appearance.
///
/// The raw values of the original five are preserved because they are persisted
/// in the stored appearance settings; `officialDark` and `nativeLight` now name
/// the same neutral family, which is why both map to `.slate`.
public enum CodexAgentThemePreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case officialDark
    case nativeLight
    case midnight
    case warmMinimal
    case sage
    case rose
    case violet
    case highContrast

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .officialDark: return "Slate"
        case .nativeLight: return "Paper"
        case .midnight: return "Midnight"
        case .warmMinimal: return "Warm Sand"
        case .sage: return "Sage"
        case .rose: return "Rose"
        case .violet: return "Violet"
        case .highContrast: return "High Contrast"
        }
    }

    /// A one-line character description for the settings picker.
    public var summary: String {
        switch self {
        case .officialDark: return "Neutral graphite. Nothing competes with syntax."
        case .nativeLight: return "Neutral, biased bright."
        case .midnight: return "Deep cool blue with a cyan accent."
        case .warmMinimal: return "Paper and lamplight."
        case .sage: return "Muted green. The calmest family."
        case .rose: return "Dusty rose, warm without yellow."
        case .violet: return "Cool violet, low chroma."
        case .highContrast: return "Maximum contrast for legibility."
        }
    }

    public var palette: CodexPaletteSpec {
        switch self {
        case .officialDark, .nativeLight: return .slate
        case .midnight: return .midnight
        case .warmMinimal: return .warmSand
        case .sage: return .sage
        case .rose: return .rose
        case .violet: return .violet
        case .highContrast: return .highContrast
        }
    }

    /// The appearance this family is shown in when the user has not chosen one.
    /// Only meaningful for the two legacy presets, whose names carried an
    /// appearance before palettes became dual.
    public var impliedAppearance: CodexAppearanceMode {
        switch self {
        case .officialDark: return .dark
        case .nativeLight: return .light
        default: return .system
        }
    }

    public var theme: CodexAgentTheme {
        CodexAgentTheme(
            colors: CodexAgentTheme.Colors(spec: palette),
            effects: effects
        )
    }

    /// The same theme with colors resolved for one known appearance, for
    /// AppKit-backed views that cannot use adaptive colors.
    public func theme(resolvedFor scheme: ColorScheme) -> CodexAgentTheme {
        CodexAgentTheme(
            colors: CodexAgentTheme.Colors(spec: palette, resolvedFor: scheme),
            effects: effects
        )
    }

    private var effects: CodexAgentTheme.Effects {
        switch self {
        case .highContrast:
            // The only family that opts out of glass, because its whole purpose
            // is flat maximum contrast. Reduce Transparency covers every other
            // family independently of this choice.
            return .init(usesLiquidGlass: false, surfaceOpacity: 1, glowOpacity: 0)
        case .midnight:
            return .init(usesLiquidGlass: true, surfaceOpacity: 0.88, glowOpacity: 0.20)
        case .warmMinimal:
            return .init(usesLiquidGlass: true, surfaceOpacity: 0.90, glowOpacity: 0.12)
        case .officialDark, .nativeLight, .sage, .rose, .violet:
            return .init(usesLiquidGlass: true, surfaceOpacity: 0.90, glowOpacity: 0.14)
        }
    }
}

/// Whether the app follows the system appearance or pins one.
public enum CodexAppearanceMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    public var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
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
