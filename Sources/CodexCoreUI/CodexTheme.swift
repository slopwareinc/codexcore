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
public enum CodexTheme {
    public static var canvas: Color { .codexAdaptive(codexHex(0xF4F5F8), codexHex(0x0B0C0F)) }
    public static var surface: Color { .codexAdaptive(codexHex(0xFFFFFF), codexHex(0x16181D)) }
    public static var surfaceSunken: Color { .codexAdaptive(codexHex(0xEDEFF3), codexHex(0x101216)) }

    public static var primary: Color { .codexAdaptive(codexHex(0x14161C), codexHex(0xF2F3F6)) }
    public static var secondary: Color { .codexAdaptive(codexHex(0x565C68), codexHex(0xA4AAB6)) }
    public static var tertiary: Color { .codexAdaptive(codexHex(0x8A909C), codexHex(0x6B7280)) }

    public static var accent: Color { .codexAdaptive(codexHex(0x534FE3), codexHex(0x7C84FF)) }
    public static var accentSoft: Color { .codexAdaptive(codexHex(0xE9E8FF), codexHex(0x232746)) }
    public static var onAccent: Color { .white }

    public static var stroke: Color { .codexAdaptive(.black.opacity(0.08), .white.opacity(0.10)) }
    public static var strokeStrong: Color { .codexAdaptive(.black.opacity(0.14), .white.opacity(0.16)) }

    public static var success: Color { .codexAdaptive(codexHex(0x1A8B4B), codexHex(0x44D17E)) }
    public static var warning: Color { .codexAdaptive(codexHex(0xB4690E), codexHex(0xE7A23C)) }
    public static var danger: Color { .codexAdaptive(codexHex(0xC8392B), codexHex(0xFF6B66)) }
    public static var running: Color { .codexAdaptive(codexHex(0x2D6FF0), codexHex(0x5C9BFF)) }
    public static var tool: Color { .codexAdaptive(codexHex(0x7C3AED), codexHex(0xA78BFA)) }

    public static var codeBG: Color { codexHex(0x0C0E13) }
    public static var codeBGHeader: Color { codexHex(0x15181F) }
    public static var codeText: Color { codexHex(0xD6DBE4) }
    public static var codeFaint: Color { codexHex(0x8A93A4) }
    public static var codeStroke: Color { .white.opacity(0.08) }

    public static var userBubble: Color { .codexAdaptive(codexHex(0xE7E9FF), codexHex(0x252A4A)) }
    public static var userBubbleStroke: Color { .codexAdaptive(codexHex(0x534FE3).opacity(0.18), codexHex(0x7C84FF).opacity(0.22)) }

    public enum Radius {
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 9
        public static let lg: CGFloat = 12
        public static let xl: CGFloat = 16
        public static let pill: CGFloat = 999
    }

    public enum Space {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
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
        _ shape: S = RoundedRectangle(cornerRadius: CodexTheme.Radius.lg, style: .continuous),
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            self.glassEffect(makeCodexGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(CodexTheme.stroke, lineWidth: 1))
        }
    }
}

/// A soft Codex chat backdrop that adapts to light and dark appearances.
public struct CodexBackdrop: View {
    public init() {}

    public var body: some View {
        ZStack {
            CodexTheme.canvas
            RadialGradient(
                colors: [CodexTheme.accent.opacity(0.16), .clear],
                center: .topTrailing, startRadius: 1, endRadius: 720
            )
            RadialGradient(
                colors: [CodexTheme.accent.opacity(0.08), .clear],
                center: .bottomLeading, startRadius: 1, endRadius: 640
            )
        }
        .ignoresSafeArea()
    }
}

/// Codex brand mark used by chat rows, empty states, and launch panels.
public struct CodexBrandMark: View {
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
                        colors: [CodexTheme.accent, CodexTheme.accent.opacity(0.7)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            Image(systemName: systemImage)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: CodexTheme.accent.opacity(0.32), radius: size * 0.32, y: size * 0.16)
    }
}
