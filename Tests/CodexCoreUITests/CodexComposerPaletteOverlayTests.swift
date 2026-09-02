import AppKit
import SwiftUI
import Testing
@testable import CodexCoreUI

@MainActor
struct CodexComposerPaletteOverlayTests {
    @Test func genericInvocationQueryBecomesAStructuredTagWithoutPromptText() {
        #expect(CodexMentionQuery.query(from: "Explain this with @Visu") == "Visu")
        #expect(
            CodexMentionQuery.removingQuery(from: "Explain this with @Visu")
                == "Explain this with"
        )
    }

    @Test func repeatedComposerHeightPreferencesAreRenderNeutral() {
        #expect(CodexComposerOverlayHeightReconciler.next(current: 170, proposed: 170) == nil)
        #expect(CodexComposerOverlayHeightReconciler.next(current: 170, proposed: 170.4) == nil)
        #expect(CodexComposerOverlayHeightReconciler.next(current: 170, proposed: 0) == nil)
        #expect(CodexComposerOverlayHeightReconciler.next(current: 170, proposed: 172) == 172)
    }

    @Test func slashPaletteDoesNotChangeComposerMeasuredHeight() {
        let idle = hosting(draft: "")
        let slash = hosting(draft: "/")

        #expect(abs(idle.fittingSize.height - slash.fittingSize.height) < 1)
        #expect(idle.fittingSize.height > 0)
    }

    @Test func largeSlashCatalogHasBoundedFirstMeasurement() {
        let commands = (0..<1_000).map { index in
            CodexSlashCommand(
                id: "command-\(index)",
                title: "Command \(index)",
                detail: "Synthetic command",
                systemImage: "terminal",
                section: "Commands"
            )
        }
        let start = ContinuousClock.now
        let view = CodexComposerBar(
            draft: .constant("/"),
            slashCommands: commands,
            isSending: false,
            canSend: true,
            onSend: {},
            onInterrupt: {}
        )
        .frame(width: 736)
        .codexAgentTheme(.officialDark)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(x: 0, y: 0, width: 736, height: 160)
        hosting.layoutSubtreeIfNeeded()

        #expect(start.duration(to: .now) < .seconds(1))
        #expect(hosting.fittingSize.height < 200)
    }

    @Test func skillMentionRendersInsideTheNativeTextFlow() throws {
        let skill = CodexSlashCommand(
            id: "skill:visualize",
            title: "Visualize",
            detail: "Create an inline visual",
            systemImage: "sparkles",
            section: "Skills",
            skillName: "visualize",
            skillPath: "/skills/visualize/SKILL.md"
        )
        let view = CodexComposerBar(
            draft: .constant("Use  here"),
            slashCommands: [skill],
            isSending: false,
            canSend: true,
            attachedSkills: [skill],
            skillPlacements: [.init(skillID: skill.id, utf16Offset: 4)],
            onSend: {},
            onInterrupt: {}
        )
        .frame(width: 736)
        .codexAgentTheme(.officialDark)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(x: 0, y: 0, width: 736, height: 160)
        hosting.layoutSubtreeIfNeeded()
        let textView = try #require(firstTextView(in: hosting))
        let attachmentCount = textView.textStorage?.attribute(
            .attachment,
            at: 4,
            effectiveRange: nil
        ) == nil ? 0 : 1

        #expect(attachmentCount == 1)
        #expect(textView.string == "Use \u{fffc} here")
    }

    @Test func nativeEditingMovesAndAtomicallyDeletesInlineSkillMentions() throws {
        let skill = CodexSlashCommand(
            id: "skill:visualize",
            title: "Visualize",
            detail: "Create an inline visual",
            systemImage: "sparkles",
            section: "Skills",
            skillName: "visualize",
            skillPath: "/skills/visualize/SKILL.md"
        )
        let model = InlineComposerTestModel(
            draft: "Use  here",
            skills: [skill],
            placements: [.init(skillID: skill.id, utf16Offset: 4)]
        )
        let view = CodexComposerBar(
            draft: Binding(get: { model.draft }, set: { model.draft = $0 }),
            slashCommands: [skill],
            isSending: false,
            canSend: true,
            attachedSkills: model.skills,
            skillPlacements: model.placements,
            onSkillTagRemoved: { id in model.skills.removeAll { $0.id == id } },
            onSkillPlacementsChanged: { model.placements = $0 },
            onSend: {},
            onInterrupt: {}
        )
        .frame(width: 736)
        .codexAgentTheme(.officialDark)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(x: 0, y: 0, width: 736, height: 160)
        hosting.layoutSubtreeIfNeeded()
        let textView = try #require(firstTextView(in: hosting))

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("Please ", replacementRange: textView.selectedRange())
        #expect(model.draft == "Please Use  here")
        #expect(model.placements == [.init(skillID: skill.id, utf16Offset: 11)])

        textView.setSelectedRange(NSRange(location: 12, length: 0))
        textView.deleteBackward(nil)
        #expect(model.skills.isEmpty)
        #expect(model.placements.isEmpty)
        #expect(!textView.string.contains("\u{fffc}"))
    }

    private func hosting(draft: String) -> NSHostingView<AnyView> {
        let view = CodexComposerBar(
            draft: .constant(draft),
            isSending: false,
            canSend: true,
            onSend: {},
            onInterrupt: {}
        )
        .frame(width: 736)
        .codexAgentTheme(.officialDark)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(x: 0, y: 0, width: 736, height: 160)
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    private func firstTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = firstTextView(in: subview) { return found }
        }
        return nil
    }
}

@MainActor
private final class InlineComposerTestModel {
    var draft: String
    var skills: [CodexSlashCommand]
    var placements: [CodexComposerSkillPlacement]

    init(
        draft: String,
        skills: [CodexSlashCommand],
        placements: [CodexComposerSkillPlacement]
    ) {
        self.draft = draft
        self.skills = skills
        self.placements = placements
    }
}
