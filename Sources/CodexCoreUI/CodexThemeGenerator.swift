import Foundation

// Generated theme palettes.
//
// A theme used to be 33 roles x 2 appearances of hand-picked hex values. That
// made every family a guess that had to be re-verified by hand, and it made a
// user-chosen accent impossible: nobody can hand-tune a palette for every hue.
//
// A theme is now a `CodexThemeSeed` — a neutral tint, an accent, and the hues of
// its atmosphere — and every role is *derived* in OKLCH. Lightness carries the
// hierarchy, chroma carries the character, and hue carries the identity, so the
// three can be reasoned about independently. Wherever a role is read as text,
// its lightness is *solved* against the surface it sits on until it clears the
// contrast target, which is what lets any accent hue stay legible in both
// appearances.

/// The inputs a theme is generated from.
public struct CodexThemeSeed: Equatable, Hashable, Sendable, Codable {
    /// Hue of the neutral surfaces, in degrees.
    public var neutralHue: Double
    /// How strongly surfaces lean toward `neutralHue`. Around 0.004 reads as
    /// neutral graphite; 0.02 is clearly tinted. Keep it low: saturated
    /// backgrounds stop being restful after ten minutes of reading code.
    public var neutralChroma: Double
    /// Hue of the accent, in degrees.
    public var accentHue: Double
    /// Accent saturation. 0.10 is muted, 0.18 is vivid.
    public var accentChroma: Double
    /// Hues of the atmosphere's light fields. The first is the strongest.
    public var atmosphereHues: [Double]
    /// Saturation of the atmosphere's light fields.
    public var atmosphereChroma: Double

    public init(
        neutralHue: Double,
        neutralChroma: Double,
        accentHue: Double,
        accentChroma: Double,
        atmosphereHues: [Double]? = nil,
        atmosphereChroma: Double = 0.11
    ) {
        self.neutralHue = neutralHue
        self.neutralChroma = neutralChroma
        self.accentHue = accentHue
        self.accentChroma = accentChroma
        self.atmosphereHues = atmosphereHues ?? [accentHue, accentHue - 40, accentHue + 50]
        self.atmosphereChroma = atmosphereChroma
    }

    /// The same seed with a different accent. The atmosphere follows the
    /// accent so the light in the window agrees with the controls in it.
    public func withAccentHue(_ hue: Double) -> CodexThemeSeed {
        var seed = self
        let shift = hue - accentHue
        seed.accentHue = hue
        seed.atmosphereHues = atmosphereHues.map { $0 + shift }
        return seed
    }
}

/// The light behind the window's glass: a 3x3 mesh of colors per appearance,
/// row-major from the top-leading corner. Glass refracts whatever is behind it;
/// a designed backdrop is what makes it read as glass instead of grey plastic.
public struct CodexAtmosphere: Equatable, Hashable, Sendable {
    public var light: [UInt32]
    public var dark: [UInt32]

    public init(light: [UInt32], dark: [UInt32]) {
        precondition(light.count == 9 && dark.count == 9, "An atmosphere is a 3x3 mesh")
        self.light = light
        self.dark = dark
    }

    public func colors(for isDark: Bool) -> [UInt32] {
        isDark ? dark : light
    }

    /// A flat atmosphere, for themes that opt out of glass.
    public static func flat(_ canvas: CodexColorPair) -> CodexAtmosphere {
        CodexAtmosphere(
            light: Array(repeating: canvas.light, count: 9),
            dark: Array(repeating: canvas.dark, count: 9)
        )
    }
}

// MARK: - Generation

public extension CodexThemeSeed {
    /// Every palette role for both appearances.
    var palette: CodexPaletteSpec {
        let light = CodexThemeRoles(seed: self, isDark: false)
        let dark = CodexThemeRoles(seed: self, isDark: true)
        func pair(_ role: KeyPath<CodexThemeRoles, UInt32>) -> CodexColorPair {
            CodexColorPair(light: light[keyPath: role], dark: dark[keyPath: role])
        }
        return CodexPaletteSpec(
            canvas: pair(\.canvas),
            surface: pair(\.surface),
            surfaceSunken: pair(\.surfaceSunken),
            surfaceElevated: pair(\.surfaceElevated),
            textPrimary: pair(\.textPrimary),
            textSecondary: pair(\.textSecondary),
            textTertiary: pair(\.textTertiary),
            accent: pair(\.accent),
            accentStrong: pair(\.accentStrong),
            accentText: pair(\.accentText),
            accentSoft: pair(\.accentSoft),
            onAccent: pair(\.onAccent),
            border: pair(\.border),
            borderStrong: pair(\.borderStrong),
            userBubble: pair(\.userBubble),
            userBubbleStroke: pair(\.userBubbleStroke),
            codeBackground: pair(\.codeBackground),
            codeHeader: pair(\.codeHeader),
            codeText: pair(\.codeText),
            codeFaint: pair(\.codeFaint),
            success: pair(\.success),
            warning: pair(\.warning),
            danger: pair(\.danger),
            running: pair(\.running),
            tool: pair(\.tool),
            codeKeyword: pair(\.codeKeyword),
            codeString: pair(\.codeString),
            codeComment: pair(\.codeFaint),
            codeNumber: pair(\.codeNumber),
            scrim: CodexColorPair(light: OKLCH(0.22, neutralChroma, neutralHue).rgb, dark: 0x000000),
            shadow: CodexColorPair(light: OKLCH(0.25, neutralChroma * 2, neutralHue).rgb, dark: 0x000000)
        )
    }

    var atmosphere: CodexAtmosphere {
        CodexAtmosphere(
            light: atmosphereMesh(isDark: false),
            dark: atmosphereMesh(isDark: true)
        )
    }

    /// Light pools in the corners where chrome lives — the sidebar's top, the
    /// toolbar's trailing edge — and falls away toward the reading column, so
    /// glass has something to refract without the transcript sitting on color.
    private func atmosphereMesh(isDark: Bool) -> [UInt32] {
        let hues = atmosphereHues.isEmpty ? [accentHue] : atmosphereHues
        func hue(_ index: Int) -> Double { hues[index % hues.count] }
        let base = CodexThemeRoles(seed: self, isDark: isDark).canvasColor
        func glow(_ index: Int, _ strength: Double) -> UInt32 {
            let target = isDark
                ? OKLCH(0.50, atmosphereChroma * 1.2, hue(index))
                : OKLCH(0.88, atmosphereChroma, hue(index))
            return base.mixed(with: target, by: strength).rgb
        }
        let canvas = base.rgb
        return [
            glow(0, isDark ? 0.62 : 0.70), glow(1, isDark ? 0.18 : 0.28), glow(2, isDark ? 0.46 : 0.55),
            glow(1, isDark ? 0.30 : 0.40), canvas, glow(2, isDark ? 0.10 : 0.16),
            glow(2, isDark ? 0.24 : 0.34), glow(0, isDark ? 0.08 : 0.12), canvas
        ]
    }
}

/// One appearance's worth of roles. Kept separate from `CodexPaletteSpec` so the
/// derivation reads top to bottom as a single recipe.
struct CodexThemeRoles {
    let canvasColor: OKLCH
    let canvas: UInt32
    let surface: UInt32
    let surfaceSunken: UInt32
    let surfaceElevated: UInt32
    let textPrimary: UInt32
    let textSecondary: UInt32
    let textTertiary: UInt32
    let accent: UInt32
    let accentStrong: UInt32
    let accentText: UInt32
    let accentSoft: UInt32
    let onAccent: UInt32
    let border: UInt32
    let borderStrong: UInt32
    let userBubble: UInt32
    let userBubbleStroke: UInt32
    let codeBackground: UInt32
    let codeHeader: UInt32
    let codeText: UInt32
    let codeFaint: UInt32
    let success: UInt32
    let warning: UInt32
    let danger: UInt32
    let running: UInt32
    let tool: UInt32
    let codeKeyword: UInt32
    let codeString: UInt32
    let codeNumber: UInt32

    init(seed: CodexThemeSeed, isDark: Bool) {
        let nh = seed.neutralHue
        let nc = seed.neutralChroma
        let ah = seed.accentHue
        let ac = seed.accentChroma
        func neutral(_ l: Double, chroma scale: Double = 1) -> OKLCH { OKLCH(l, nc * scale, nh) }

        // Surfaces. Dark canvases stay near black but keep the family's hue;
        // light canvases are paper, not pure white, so white cards can lift.
        let canvas = isDark ? neutral(0.165, chroma: 0.9) : neutral(0.982, chroma: 0.55)
        canvasColor = canvas
        self.canvas = canvas.rgb
        surfaceSunken = (isDark ? neutral(0.150, chroma: 0.9) : neutral(0.958, chroma: 0.8)).rgb
        surface = (isDark ? neutral(0.195) : neutral(0.995, chroma: 0.3)).rgb
        surfaceElevated = (isDark ? neutral(0.235) : OKLCH(1, 0, 0)).rgb

        // Text: primary is fixed; the rest are solved against the canvas.
        let primary = isDark ? neutral(0.965, chroma: 0.25) : neutral(0.205, chroma: 1.4)
        textPrimary = primary.rgb
        textSecondary = solve(neutral(isDark ? 0.80 : 0.45, chroma: 1.2), on: canvas, contrast: 5.2, isDark: isDark).rgb
        textTertiary = solve(neutral(isDark ? 0.64 : 0.60, chroma: 1.2), on: canvas, contrast: 3.1, isDark: isDark).rgb

        // Accent. The fill is chosen for presence; the text variant is solved
        // for legibility on the page; the glyph on the fill picks whichever of
        // ink or white reads better against it.
        let fill = isDark ? OKLCH(0.74, ac, ah) : solveFill(OKLCH(0.60, ac, ah))
        accent = fill.rgb
        accentStrong = OKLCH(isDark ? fill.l + 0.06 : fill.l - 0.07, ac, ah).rgb
        accentText = solve(OKLCH(isDark ? 0.80 : 0.52, ac, ah), on: canvas, contrast: 4.6, isDark: isDark).rgb
        accentSoft = (isDark ? OKLCH(0.30, ac * 0.38, ah) : OKLCH(0.935, ac * 0.30, ah)).rgb
        let ink = OKLCH(0.18, ac * 0.25, ah)
        onAccent = (contrastRatio(ink, fill) >= contrastRatio(OKLCH(1, 0, 0), fill) ? ink : OKLCH(1, 0, 0)).rgb

        // Lines are the text color at low alpha, so they sit correctly on any
        // surface — including glass — rather than on one assumed background.
        border = primary.rgb.withAlpha(isDark ? 0x17 : 0x16)
        borderStrong = primary.rgb.withAlpha(isDark ? 0x2E : 0x2C)

        // The user's own message carries a whisper of the accent so the two
        // voices in the transcript are distinguishable without a loud bubble.
        userBubble = (isDark ? OKLCH(0.245, ac * 0.22, ah) : OKLCH(0.952, ac * 0.16, ah)).rgb
        userBubbleStroke = fill.rgb.withAlpha(isDark ? 0x24 : 0x22)

        // Code sits slightly recessed from the canvas.
        codeBackground = (isDark ? neutral(0.140) : neutral(0.968, chroma: 0.8)).rgb
        codeHeader = (isDark ? neutral(0.205) : neutral(0.935, chroma: 0.9)).rgb
        codeText = (isDark ? neutral(0.90, chroma: 0.6) : neutral(0.27, chroma: 1.4)).rgb
        codeFaint = solve(neutral(isDark ? 0.66 : 0.58, chroma: 1.5), on: canvas, contrast: 3.6, isDark: isDark).rgb

        // Status hues are fixed so meaning survives a theme change; only their
        // lightness and a slight chroma adjust to the appearance.
        func status(_ hue: Double, _ chroma: Double) -> UInt32 {
            solve(OKLCH(isDark ? 0.78 : 0.52, chroma, hue), on: canvas, contrast: isDark ? 6.0 : 4.6, isDark: isDark).rgb
        }
        success = status(152, 0.15)
        warning = status(70, 0.15)
        danger = status(25, 0.18)
        running = status(252, 0.15)
        tool = status(305, 0.15)

        // Syntax harmonizes with the accent: keywords take it directly, the
        // others are placed at fixed offsets around the wheel.
        codeKeyword = accentText
        codeString = status(ah + 140, 0.12)
        codeNumber = status(ah + 220, 0.12)
    }
}

// MARK: - Contrast solving

/// Moves `color`'s lightness away from `background` until the pair clears
/// `contrast`. Starting from a designed lightness keeps colors that already
/// pass exactly where the recipe put them.
private func solve(_ color: OKLCH, on background: OKLCH, contrast: Double, isDark: Bool) -> OKLCH {
    var candidate = color
    let step = isDark ? 0.01 : -0.01
    while contrastRatio(candidate, background) < contrast {
        let next = candidate.l + step
        guard next >= 0, next <= 1 else { break }
        candidate = OKLCH(next, candidate.c, candidate.h)
    }
    return candidate
}

/// A light-appearance fill must carry white glyphs, so it darkens until it does.
private func solveFill(_ color: OKLCH) -> OKLCH {
    solve(color, on: OKLCH(1, 0, 0), contrast: 3.4, isDark: false)
}

private func contrastRatio(_ a: OKLCH, _ b: OKLCH) -> Double {
    let la = a.luminance
    let lb = b.luminance
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

private extension UInt32 {
    func withAlpha(_ alpha: UInt32) -> UInt32 {
        (alpha << 24) | (self & 0xFFFFFF)
    }
}

// MARK: - OKLCH

/// A color in OKLCH: perceptual lightness 0...1, chroma, hue in degrees.
/// Conversions follow Björn Ottosson's OKLab reference.
struct OKLCH: Equatable {
    var l: Double
    var c: Double
    var h: Double

    init(_ l: Double, _ c: Double, _ h: Double) {
        self.l = min(max(l, 0), 1)
        self.c = max(c, 0)
        self.h = h.truncatingRemainder(dividingBy: 360) + (h < 0 ? 360 : 0)
    }

    init(rgb: UInt32) {
        func linear(_ shift: UInt32) -> Double {
            let v = Double((rgb >> shift) & 0xFF) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let (lab_l, lab_a, lab_b) = OKLCH.oklab(r: linear(16), g: linear(8), b: linear(0))
        self.init(lab_l, hypot(lab_a, lab_b), atan2(lab_b, lab_a) * 180 / .pi)
    }

    /// The closest in-gamut sRGB value, reached by reducing chroma — never
    /// lightness, which would undo a solved contrast.
    var rgb: UInt32 {
        var chroma = c
        var linear = linearRGB(chroma: chroma)
        if !OKLCH.inGamut(linear) {
            var low = 0.0
            var high = chroma
            for _ in 0..<20 {
                let mid = (low + high) / 2
                if OKLCH.inGamut(linearRGB(chroma: mid)) { low = mid } else { high = mid }
            }
            chroma = low
            linear = linearRGB(chroma: chroma)
        }
        func encode(_ v: Double) -> UInt32 {
            let clamped = min(max(v, 0), 1)
            let gamma = clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
            return UInt32((gamma * 255).rounded())
        }
        return (encode(linear.r) << 16) | (encode(linear.g) << 8) | encode(linear.b)
    }

    /// WCAG relative luminance of the gamut-mapped color.
    var luminance: Double {
        let value = rgb
        func channel(_ shift: UInt32) -> Double {
            let v = Double((value >> shift) & 0xFF) / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    /// Interpolates in OKLab, which keeps mixes from passing through grey.
    func mixed(with other: OKLCH, by amount: Double) -> OKLCH {
        let t = min(max(amount, 0), 1)
        let (a1, b1) = ab
        let (a2, b2) = other.ab
        let l = self.l + (other.l - self.l) * t
        let a = a1 + (a2 - a1) * t
        let b = b1 + (b2 - b1) * t
        return OKLCH(l, hypot(a, b), atan2(b, a) * 180 / .pi)
    }

    private var ab: (Double, Double) {
        let radians = h * .pi / 180
        return (c * cos(radians), c * sin(radians))
    }

    private func linearRGB(chroma: Double) -> (r: Double, g: Double, b: Double) {
        let radians = h * .pi / 180
        let a = chroma * cos(radians)
        let b = chroma * sin(radians)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let l3 = l_ * l_ * l_
        let m3 = m_ * m_ * m_
        let s3 = s_ * s_ * s_
        return (
            4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
            -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
            -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3
        )
    }

    private static func inGamut(_ rgb: (r: Double, g: Double, b: Double)) -> Bool {
        let epsilon = 0.0001
        return [rgb.r, rgb.g, rgb.b].allSatisfy { $0 >= -epsilon && $0 <= 1 + epsilon }
    }

    private static func oklab(r: Double, g: Double, b: Double) -> (Double, Double, Double) {
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }
}
