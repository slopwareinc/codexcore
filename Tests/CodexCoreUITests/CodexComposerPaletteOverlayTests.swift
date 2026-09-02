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
}
