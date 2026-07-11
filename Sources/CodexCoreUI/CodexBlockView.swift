import Foundation
import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

// MARK: - Cached prose rendering

final class CachedAttributedString: NSObject {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

enum CodexProseCache {
    nonisolated(unsafe) static let cache: NSCache<NSString, CachedAttributedString> = {
        let cache = NSCache<NSString, CachedAttributedString>()
        cache.countLimit = 512
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    static func styledAttributedString(for parsed: AttributedString, digest: String, baseFont: Font, baseNSFont: NSFont?, theme: CodexAgentTheme) -> AttributedString {
        let cacheKey = "\(digest):\(fontFingerprint(baseFont)):\(baseNSFont?.fontName ?? "system"):\(baseNSFont?.pointSize ?? 0)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached.value
        }
        let styled = makeStyled(parsed, baseFont: baseFont, baseNSFont: baseNSFont, theme: theme)
        cache.setObject(CachedAttributedString(styled), forKey: cacheKey, cost: digest.utf8.count)
        return styled
    }

    static func clear() {
        cache.removeAllObjects()
    }

    private static func resolveFont(name: String, familyName: String, size: CGFloat, isBold: Bool, isItalic: Bool) -> Font {
        var resolvedName = name
        if isBold {
            if name.contains("DMSans") || familyName == "DM Sans" {
                resolvedName = "DMSans-Bold"
            } else if name.contains("BricolageGrotesque") || familyName == "Bricolage Grotesque" {
                resolvedName = "BricolageGrotesque-Bold"
            } else if name.contains("ChivoMono") || familyName == "Chivo Mono" {
                resolvedName = "ChivoMono-Bold"
            }
        }
        
        #if canImport(AppKit)
        if !name.contains("DMSans") && !familyName.contains("DM Sans") &&
           !name.contains("BricolageGrotesque") && !familyName.contains("Bricolage Grotesque") &&
           !name.contains("ChivoMono") && !familyName.contains("Chivo Mono") {
            // Standard font descriptor lookup
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: familyName
            ])
            var traits: NSFontDescriptor.SymbolicTraits = []
            if isBold { traits.insert(.bold) }
            if isItalic { traits.insert(.italic) }
            
            let resolvedDescriptor = descriptor.withSymbolicTraits(traits)
            if let resolvedNSFont = NSFont(descriptor: resolvedDescriptor, size: size) {
                return Font(resolvedNSFont)
            }
        }
        #endif
        
        var font = Font.custom(resolvedName, size: size)
        if isItalic {
            font = font.italic()
        }
        return font
    }

    static func makeStyled(_ parsed: AttributedString, baseFont: Font, baseNSFont: NSFont?, theme: CodexAgentTheme) -> AttributedString {
        guard let baseNSFont else {
            return parsed
        }

        let symbolicTraitsRaw = baseNSFont.fontDescriptor.symbolicTraits.rawValue
        let isBaseBold = (symbolicTraitsRaw & 0x02) != 0
        let isBaseItalic = (symbolicTraitsRaw & 0x01) != 0

        var rebuilt = AttributedString()
        for run in parsed.runs {
            var attributes = run.attributes
            let intent = attributes.inlinePresentationIntent

            if let intent {
                let isBold = intent.contains(.stronglyEmphasized) || isBaseBold
                let isItalic = intent.contains(.emphasized) || isBaseItalic
                let isCode = intent.contains(.code)

                if isCode {
                    let codeFont: Font
                    if let codeNSFont = theme.fonts.codeNSFont {
                        let resolvedMonoName = codeNSFont.fontName
                        let resolvedMonoFamily = codeNSFont.familyName ?? codeNSFont.fontName
                        codeFont = resolveFont(name: resolvedMonoName, familyName: resolvedMonoFamily, size: codeNSFont.pointSize, isBold: isBold, isItalic: isItalic)
                    } else {
                        codeFont = Font.system(size: baseNSFont.pointSize - 1, design: .monospaced)
                    }
                    attributes.font = codeFont
                    attributes.backgroundColor = theme.colors.accentSoft.opacity(0.4)
                    attributes.foregroundColor = theme.colors.textPrimary
                } else {
                    attributes.font = resolveFont(
                        name: baseNSFont.fontName,
                        familyName: baseNSFont.familyName ?? baseNSFont.fontName,
                        size: baseNSFont.pointSize,
                        isBold: isBold,
                        isItalic: isItalic
                    )
                }
            } else {
                attributes.font = resolveFont(
                    name: baseNSFont.fontName,
                    familyName: baseNSFont.familyName ?? baseNSFont.fontName,
                    size: baseNSFont.pointSize,
                    isBold: isBaseBold,
                    isItalic: isBaseItalic
                )
            }

            let slice = AttributedString(parsed[run.range])
            var mutableSlice = slice
            mutableSlice.setAttributes(attributes)
            rebuilt.append(mutableSlice)
        }
        return rebuilt
    }

    private static func fontFingerprint(_ font: Font) -> String {
        String(describing: font)
    }
}

// MARK: - Block views

struct CodexBlockView: View, Equatable {
    @Environment(\.codexAgentTheme) private var theme

    let block: CodexBlock

    var body: some View {
        switch block {
        case .prose(_, let text, let attributed):
            CodexProseBlock(text: text, attributed: attributed, digest: block.contentDigest)
        case .htmlFallback(_, let text):
            let fallbackAttributed = AttributedString(text)
            CodexProseBlock(text: text, attributed: fallbackAttributed, digest: block.contentDigest)
        case .code(_, let language, let code, _):
            CodexCodeBlock(language: language, code: code)
        case .table(_, let model):
            CodexTableBlockView(model: model)
        case .heading(_, let level, let text, let attributed):
            headingView(level: level, text: text, attributed: attributed)
        case .list(_, let ordered, let items):
            listView(ordered: ordered, items: items)
        }
    }

    nonisolated static func == (lhs: CodexBlockView, rhs: CodexBlockView) -> Bool {
        lhs.block == rhs.block
    }

    @ViewBuilder
    private func headingView(level: Int, text: String, attributed: AttributedString) -> some View {
        let size: CGFloat = {
            switch level {
            case 1: return 20
            case 2: return 17
            case 3: return 15
            case 4: return 14
            default: return 13
            }
        }()
        Text(CodexProseCache.styledAttributedString(
            for: attributed,
            digest: text,
            baseFont: .system(size: size, weight: .semibold),
            baseNSFont: theme.fonts.chatNSFont.map { chatFont in
                let fontName = chatFont.fontName
                let resolvedName: String
                if fontName.contains("DMSans") {
                    resolvedName = "DMSans-Bold"
                } else if fontName.contains("BricolageGrotesque") {
                    resolvedName = "BricolageGrotesque-Bold"
                } else if fontName.contains("ChivoMono") {
                    resolvedName = "ChivoMono-Bold"
                } else {
                    resolvedName = fontName
                }
                return NSFont(name: resolvedName, size: size) ?? chatFont
            },
            theme: theme
        ))
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(theme.colors.textPrimary)
    }

    @ViewBuilder
    private func listView(ordered: Bool, items: [CodexListItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                HStack(alignment: .top, spacing: 8) {
                    Text(verbatim: ordered ? "\(offset + 1)." : "•")
                        .font(theme.fonts.chat)
                        .foregroundStyle(theme.colors.textSecondary)
                        .frame(minWidth: 16, alignment: .trailing)
                    Text(CodexProseCache.styledAttributedString(
                        for: item.attributed,
                        digest: "\(item.id):\(item.text)",
                        baseFont: theme.fonts.chat,
                        baseNSFont: theme.fonts.chatNSFont,
                        theme: theme
                    ))
                    .font(theme.fonts.chat)
                    .foregroundStyle(theme.colors.textPrimary)
                }
                .padding(.leading, CGFloat(item.depth) * 16)
            }
        }
    }
}

@MainActor
struct CodexProseBlock: View, Equatable {
    @Environment(\.codexAgentTheme) private var theme

    let text: String
    let attributed: AttributedString
    let digest: String

    var body: some View {
        Text(CodexProseCache.styledAttributedString(
            for: attributed,
            digest: digest,
            baseFont: theme.fonts.chat,
            baseNSFont: theme.fonts.chatNSFont,
            theme: theme
        ))
        // Base size for the markdown. Without a chatNSFont, styledAttributedString
        // returns the parsed runs unstyled, so this modifier is what keeps prose
        // at the chat size (matching the user bubble) instead of default .body.
        .font(theme.fonts.chat)
        .foregroundStyle(theme.colors.textPrimary)
        .lineSpacing(theme.spacing.chatLineSpacing)
    }

    nonisolated static func == (lhs: CodexProseBlock, rhs: CodexProseBlock) -> Bool {
        lhs.digest == rhs.digest && lhs.text == rhs.text
    }
}

