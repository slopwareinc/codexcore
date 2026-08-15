import AppKit
import SwiftUI
import Testing
@testable import CodexCoreApp
@testable import CodexCoreUI

@MainActor
@Suite("Theme-aligned app icon")
struct CodexThemedAppIconTests {
    @Test("Uses the approved rosette geometry and Slate tint")
    func approvedConfiguration() {
        #expect(CodexThemedAppIcon.containerScale == 0.865)
        #expect(CodexThemedAppIcon.internalScale == 0.87)
        #expect(CodexThemedAppIcon.gradientAngle == 265)
        #expect(CodexThemedAppIcon.tintValue(for: .official, colorScheme: .dark) == 0x7E9DA5)
    }

    @Test("Theme families and pinned icon appearances select palette accents")
    func themeTintSelection() {
        var settings = CodexAppearanceSettings(preset: .rose, appearanceMode: .system)
        #expect(
            CodexThemedAppIcon.tintValue(for: settings, colorScheme: .light)
                == CodexAgentThemePreset.rose.palette.accent.light
        )

        settings.dockIconVariant = .codexDark
        #expect(
            CodexThemedAppIcon.tintValue(for: settings, colorScheme: .light)
                == CodexAgentThemePreset.rose.palette.accent.dark
        )
    }

    @Test("Bundled master renders a full-resolution icon")
    func render() throws {
        let image = try #require(
            CodexThemedAppIcon.render(
                settings: CodexAppearanceSettings(preset: .sage, appearanceMode: .dark),
                colorScheme: .dark
            )
        )
        #expect(image.size == CodexThemedAppIcon.canvasSize)

        let occupiedFraction = try #require(alphaOccupiedWidthFraction(of: image))
        #expect(occupiedFraction >= 0.85)
        #expect(occupiedFraction <= 0.88)
    }

    private func alphaOccupiedWidthFraction(of image: NSImage) -> CGFloat? {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[y * bytesPerRow + x * 4 + 3] > 1 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGFloat(maxX - minX + 1) / CGFloat(width)
    }
}
