import AppKit
import SwiftUI
import CodexCoreUI

@MainActor
enum CodexThemedAppIcon {
    static let canvasSize = NSSize(width: 1_024, height: 1_024)
    /// Standard macOS icons occupy roughly 86–88% of their transparent canvas.
    static let containerScale: CGFloat = 0.865
    static let internalScale: CGFloat = 0.87
    static let gradientAngle: CGFloat = 265
    static let slateTint: UInt32 = 0x7E9DA5
    private static var cachedMasterImage: NSImage?

    static func apply(settings: CodexAppearanceSettings, colorScheme: ColorScheme) {
        guard let image = render(settings: settings, colorScheme: colorScheme) else { return }
        NSApplication.shared.applicationIconImage = image
    }

    static func render(
        settings: CodexAppearanceSettings,
        colorScheme: ColorScheme
    ) -> NSImage? {
        guard let master = masterImage() else { return nil }
        let tint = nsColor(hex: tintValue(for: settings, colorScheme: colorScheme))
        let mark = tintedMaster(master, tint: tint)
        let iconSide = canvasSize.width * containerScale
        let iconRect = NSRect(
            x: (canvasSize.width - iconSide) / 2,
            y: (canvasSize.height - iconSide) / 2,
            width: iconSide,
            height: iconSide
        )
        let markSide = iconSide * internalScale
        let markRect = NSRect(
            x: (canvasSize.width - markSide) / 2,
            y: (canvasSize.height - markSide) / 2,
            width: markSide,
            height: markSide
        )

        return NSImage(size: canvasSize, flipped: false) { _ in
            let background = NSBezierPath(
                roundedRect: iconRect.insetBy(dx: 2, dy: 2),
                xRadius: iconSide * 0.215,
                yRadius: iconSide * 0.215
            )
            guard let gradient = NSGradient(colors: [
                pastel(tint, whiteFraction: 0.88),
                pastel(tint, whiteFraction: 0.72),
                pastel(tint, whiteFraction: 0.48),
            ]) else { return false }

            NSGraphicsContext.saveGraphicsState()
            background.addClip()
            gradient.draw(in: background, angle: gradientAngle)

            let shadow = NSShadow()
            shadow.shadowColor = tint.withAlphaComponent(0.20)
            shadow.shadowBlurRadius = iconSide * 0.038
            shadow.shadowOffset = NSSize(width: 0, height: -iconSide * 0.018)
            shadow.set()
            mark.draw(in: markRect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()

            NSColor.white.withAlphaComponent(0.72).setStroke()
            background.lineWidth = iconSide * 0.005
            background.stroke()
            return true
        }
    }

    static func tintValue(
        for settings: CodexAppearanceSettings,
        colorScheme: ColorScheme
    ) -> UInt32 {
        switch settings.preset {
        case .officialDark, .nativeLight:
            slateTint
        default:
            settings.preset.palette.accent.value(for: iconColorScheme(settings, fallback: colorScheme))
        }
    }

    private static func iconColorScheme(
        _ settings: CodexAppearanceSettings,
        fallback: ColorScheme
    ) -> ColorScheme {
        switch settings.dockIconVariant {
        case .default: fallback
        case .codexLight: .light
        case .codexDark: .dark
        }
    }

    private static func masterImage() -> NSImage? {
        if let cachedMasterImage {
            return cachedMasterImage
        }

        let image: NSImage?
        if let url = Bundle.main.url(forResource: "CodexAppIconMaster", withExtension: "png"),
           let bundledImage = NSImage(contentsOf: url) {
            image = bundledImage
        } else {
            #if SWIFT_PACKAGE
            if let url = Bundle.module.url(forResource: "CodexAppIconMaster", withExtension: "png") {
                image = NSImage(contentsOf: url)
            } else {
                image = nil
            }
            #else
            image = nil
            #endif
        }

        if let image {
            cachedMasterImage = image
        }
        return image
    }

    private static func tintedMaster(_ master: NSImage, tint: NSColor) -> NSImage {
        NSImage(size: master.size, flipped: false) { bounds in
            master.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
            if let context = NSGraphicsContext.current?.cgContext {
                context.setBlendMode(.sourceAtop)
                context.setFillColor(tint.cgColor)
                context.fill(bounds)
            }
            master.draw(in: bounds, from: .zero, operation: .multiply, fraction: 0.68)
            master.draw(in: bounds, from: .zero, operation: .screen, fraction: 0.24)
            return true
        }
    }

    private static func pastel(_ color: NSColor, whiteFraction: CGFloat) -> NSColor {
        color.blended(withFraction: whiteFraction, of: .white) ?? color
    }

    private static func nsColor(hex value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
