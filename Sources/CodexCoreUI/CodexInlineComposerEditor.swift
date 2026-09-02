#if canImport(AppKit)
import AppKit
import CodexCore
import SwiftUI

private extension NSAttributedString.Key {
    static let codexComposerSkillID = NSAttributedString.Key("com.slopware.codexcore.composer-skill-id")
}

fileprivate final class CodexComposerTextView: NSTextView {
    var placeholder = "" { didSet { needsDisplay = true } }
    var placeholderColor = NSColor.placeholderTextColor { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: placeholderColor,
        ]
        NSString(string: placeholder).draw(
            at: CGPoint(x: textContainerInset.width + 1, y: textContainerInset.height),
            withAttributes: attributes
        )
    }
}

@MainActor
struct CodexInlineComposerEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var skills: [CodexSlashCommand]
    var placements: [CodexComposerSkillPlacement]
    var placeholder: String
    var maximumLines: Int
    var theme: CodexAgentTheme
    var colorScheme: ColorScheme
    var onPlacementsChanged: ([CodexComposerSkillPlacement]) -> Void
    var onRemoveSkill: (String) -> Void
    var onSubmit: () -> Void
    var onHeightChanged: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.borderType = .noBorder

        let textView = CodexComposerTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 6, height: 5)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.setAccessibilityLabel(placeholder)
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.apply(parent: self, force: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.apply(parent: self, force: false)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodexInlineComposerEditor
        fileprivate weak var textView: CodexComposerTextView?
        weak var scrollView: NSScrollView?
        private var isApplying = false
        private var lastHeight: CGFloat = 0
        private var appearanceFingerprint = ""
        private var cachedText = ""
        private var cachedPlacements: [CodexComposerSkillPlacement] = []

        init(parent: CodexInlineComposerEditor) {
            self.parent = parent
        }

        func apply(parent: CodexInlineComposerEditor, force: Bool) {
            self.parent = parent
            guard let textView else { return }
            let font = parent.theme.fonts.chatNSFont ?? NSFont.systemFont(ofSize: 15)
            let appearance = NSAppearance(named: parent.colorScheme == .dark ? .darkAqua : .aqua)
            let textColor = CodexAppKitColor.resolve(parent.theme.colors.textPrimary, for: appearance)
            let mentionColor = CodexAppKitColor.resolve(parent.theme.colors.accentText, for: appearance)
            let fingerprint = "\(font.fontName):\(font.pointSize):\(mentionColor.description):\(textColor.description)"
            textView.font = font
            textView.textColor = textColor
            textView.typingAttributes = [.font: font, .foregroundColor: textColor]
            textView.placeholder = parent.placeholder
            textView.placeholderColor = CodexAppKitColor.resolve(parent.theme.colors.textTertiary, for: appearance)

            let requested = normalizedPlacements(parent.placements, textUTF16Count: parent.text.utf16.count)
            if force || cachedText != parent.text || cachedPlacements != requested
                || appearanceFingerprint != fingerprint {
                let previousIDs = Set(cachedPlacements.map(\.skillID))
                rebuild(
                    textView: textView,
                    text: parent.text,
                    skills: parent.skills,
                    placements: requested,
                    font: font,
                    textColor: textColor,
                    mentionColor: mentionColor,
                    focusNewSkill: Set(requested.map(\.skillID)).subtracting(previousIDs).first
                )
                cachedText = parent.text
                cachedPlacements = requested
                appearanceFingerprint = fingerprint
            }
            if parent.isFocused, textView.window?.firstResponder !== textView {
                textView.window?.makeFirstResponder(textView)
            } else if !parent.isFocused, textView.window?.firstResponder === textView {
                textView.window?.makeFirstResponder(nil)
            }
            updateHeight()
        }

        func textDidBeginEditing(_ notification: Notification) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textDidEndEditing(_ notification: Notification) {
            if parent.isFocused { parent.isFocused = false }
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplying, let textView else { return }
            let document = readDocument(from: textView)
            cachedText = document.text
            cachedPlacements = document.placements
            if parent.text != document.text { parent.text = document.text }
            let knownIDs = Set(parent.skills.map(\.id))
            let documentIDs = Set(document.placements.map(\.skillID))
            for id in knownIDs.subtracting(documentIDs) { parent.onRemoveSkill(id) }
            if normalizedPlacements(parent.placements, textUTF16Count: document.text.utf16.count)
                != document.placements {
                parent.onPlacementsChanged(document.placements)
            }
            updateHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            parent.onSubmit()
            return true
        }

        private func rebuild(
            textView: NSTextView,
            text: String,
            skills: [CodexSlashCommand],
            placements: [CodexComposerSkillPlacement],
            font: NSFont,
            textColor: NSColor,
            mentionColor: NSColor,
            focusNewSkill: String?
        ) {
            let result = NSMutableAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: textColor]
            )
            let skillsByID = Dictionary(uniqueKeysWithValues: skills.map { ($0.id, $0) })
            var inserted = 0
            var focusedLocation: Int?
            for placement in placements.sorted(by: {
                $0.utf16Offset == $1.utf16Offset
                    ? skillOrder($0.skillID, in: skills) < skillOrder($1.skillID, in: skills)
                    : $0.utf16Offset < $1.utf16Offset
            }) {
                guard let skill = skillsByID[placement.skillID] else { continue }
                let attachment = NSTextAttachment()
                attachment.image = skillImage(skill, font: font, color: mentionColor)
                let rendered = NSMutableAttributedString(attachment: attachment)
                rendered.addAttribute(.codexComposerSkillID, value: skill.id, range: NSRange(location: 0, length: 1))
                let location = min(result.length, placement.utf16Offset + inserted)
                result.insert(rendered, at: location)
                if placement.skillID == focusNewSkill { focusedLocation = location + 1 }
                inserted += 1
            }
            isApplying = true
            textView.textStorage?.setAttributedString(result)
            if let focusedLocation {
                let next = min(result.length, focusedLocation + ((result.string as NSString).substring(from: focusedLocation).hasPrefix(" ") ? 1 : 0))
                textView.setSelectedRange(NSRange(location: next, length: 0))
            }
            isApplying = false
        }

        private func readDocument(from textView: NSTextView) -> (text: String, placements: [CodexComposerSkillPlacement]) {
            guard let storage = textView.textStorage else { return ("", []) }
            let plain = NSMutableString()
            var placements: [CodexComposerSkillPlacement] = []
            var cursor = 0
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
                if let skillID = attributes[.codexComposerSkillID] as? String {
                    placements.append(.init(skillID: skillID, utf16Offset: plain.length))
                } else {
                    let value = (storage.string as NSString).substring(with: range)
                    plain.append(value)
                }
                cursor = NSMaxRange(range)
            }
            if cursor < storage.length {
                plain.append((storage.string as NSString).substring(from: cursor))
            }
            return (plain as String, placements)
        }

        private func normalizedPlacements(
            _ placements: [CodexComposerSkillPlacement],
            textUTF16Count: Int
        ) -> [CodexComposerSkillPlacement] {
            placements.map {
                .init(skillID: $0.skillID, utf16Offset: min(max(0, $0.utf16Offset), textUTF16Count))
            }
        }

        private func skillOrder(_ id: String, in skills: [CodexSlashCommand]) -> Int {
            skills.firstIndex(where: { $0.id == id }) ?? .max
        }

        private func skillImage(_ skill: CodexSlashCommand, font: NSFont, color: NSColor) -> NSImage {
            let title = "@\(skill.title)" as NSString
            let labelFont = NSFont.systemFont(ofSize: font.pointSize, weight: .medium)
            let titleSize = title.size(withAttributes: [.font: labelFont])
            let iconSize = max(13, font.pointSize)
            let size = NSSize(width: ceil(iconSize + 5 + titleSize.width), height: ceil(max(iconSize, titleSize.height) + 2))
            return NSImage(size: size, flipped: false) { rect in
                let symbol = NSImage(systemSymbolName: skill.systemImage, accessibilityDescription: skill.title)
                symbol?.withSymbolConfiguration(.init(pointSize: iconSize, weight: .medium))?
                    .draw(in: NSRect(x: 0, y: (rect.height - iconSize) / 2, width: iconSize, height: iconSize))
                title.draw(
                    at: CGPoint(x: iconSize + 5, y: (rect.height - titleSize.height) / 2),
                    withAttributes: [.font: labelFont, .foregroundColor: color]
                )
                return true
            }
        }

        private func updateHeight() {
            guard let textView, let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let lineHeight = textView.font.map { $0.ascender - $0.descender + $0.leading } ?? 18
            let content = ceil(layoutManager.usedRect(for: textContainer).height + textView.textContainerInset.height * 2)
            let height = min(max(lineHeight + 10, content), lineHeight * CGFloat(max(1, parent.maximumLines)) + 10)
            scrollView?.hasVerticalScroller = content > height + 1
            guard abs(height - lastHeight) > 0.5 else { return }
            lastHeight = height
            let onHeightChanged = parent.onHeightChanged
            Task { @MainActor in onHeightChanged(height) }
        }
    }
}
#endif
