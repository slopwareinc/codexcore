import Foundation
import SwiftUI

// Ported from T3 Code's projectIdentity.ts, ProjectMonogram.tsx, and
// projectIconColors.ts at 3e6b45028ceec5820dacb37dc3852470ebdc9411.
// Copyright (c) 2026 T3 Tools Inc. MIT; see THIRD_PARTY_NOTICES.md.

/// A deterministic local fallback for T3's project favicon. It uses the project
/// name rather than a path, and does not fetch an image or probe the filesystem.
struct CodexT3ProjectIdentity: Equatable {
    let monogram: String
    let colorIndex: Int

    init(projectName: String) {
        let normalized = projectName.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = normalized.unicodeScalars.split(whereSeparator: { !Self.isWordScalar($0) })
            .map { String(String.UnicodeScalarView($0)) }
        if let firstWord = words.first {
            let glyphs = Array(firstWord.unicodeScalars)
            let first = glyphs.first.map(String.init) ?? "P"
            let second = glyphs.dropFirst().first(where: Self.isNumberScalar)
                .map(String.init)
                ?? (words.count > 1 ? words.last?.unicodeScalars.first.map(String.init) : glyphs.last.map(String.init))
                ?? first
            monogram = String(String.UnicodeScalarView((first + second).uppercased().unicodeScalars.prefix(2)))
        } else {
            monogram = "PR"
        }
        let seed = normalized.lowercased(with: Locale(identifier: "en_US")).nilIfBlank ?? "project"
        colorIndex = seed.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % Self.colors.count }
    }

    var color: CodexColorPair { Self.colors[colorIndex] }

    private static func isNumberScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: true
        default: false
        }
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: isNumberScalar(scalar)
        }
    }

    // Tailwind's *-600 light and *-400 dark project icon colors, in the same
    // order as PROJECT_ICON_COLORS. Keeping this order preserves upstream IDs.
    private static let colors: [CodexColorPair] = [
        .init(light: 0x4A5565, dark: 0x99A1AF), // gray
        .init(light: 0xE7000B, dark: 0xFF6467), // red
        .init(light: 0xF54A00, dark: 0xFF8904), // orange
        .init(light: 0xE17100, dark: 0xFFBA00), // amber
        .init(light: 0xD08700, dark: 0xFDC700), // yellow
        .init(light: 0x5EA500, dark: 0x9AE600), // lime
        .init(light: 0x00A63E, dark: 0x05DF72), // green
        .init(light: 0x009966, dark: 0x00D492), // emerald
        .init(light: 0x009689, dark: 0x00D5BE), // teal
        .init(light: 0x0092B8, dark: 0x00D3F2), // cyan
        .init(light: 0x0084D1, dark: 0x00BCFF), // sky
        .init(light: 0x155DFC, dark: 0x51A2FF), // blue
        .init(light: 0x4F39F6, dark: 0x7C86FF), // indigo
        .init(light: 0x7F22FE, dark: 0xA684FF), // violet
        .init(light: 0x9810FA, dark: 0xC27AFF), // purple
        .init(light: 0xC800DE, dark: 0xED6AFF), // fuchsia
        .init(light: 0xE60076, dark: 0xFB64B6), // pink
        .init(light: 0xEC003F, dark: 0xFF637E), // rose
    ]
}

struct CodexT3ProjectMonogram: View {
    @Environment(\.colorScheme) private var colorScheme

    let projectName: String
    var size: CGFloat = 16

    var body: some View {
        let identity = CodexT3ProjectIdentity(projectName: projectName)
        let color = identity.color.resolved(colorScheme)
        Text(identity.monogram)
            .font(.system(size: size * 8.25 / 16, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: size / 4))
            .accessibilityHidden(true)
    }
}
