import SwiftUI
import XCTest
@testable import CodexCoreUI

@MainActor
final class CodexCardRenderingTests: XCTestCase {
    func testCardsRenderAcrossThemePresets() throws {
        for preset in CodexAgentThemePreset.allCases {
            try assertRenders(CodexCommandCard(run: Self.commandRun).codexAgentTheme(preset.theme), name: "command-\(preset.rawValue)")
            try assertRenders(CodexFileChangeCard(change: Self.fileChange).codexAgentTheme(preset.theme), name: "file-\(preset.rawValue)")
            try assertRenders(CodexToolCallCard(toolCall: Self.toolCall).codexAgentTheme(preset.theme), name: "tool-\(preset.rawValue)")
            try assertRenders(CodexNoticeCard(notice: Self.notice).codexAgentTheme(preset.theme), name: "notice-\(preset.rawValue)")
            try assertRenders(CodexReasoningCard(block: Self.reasoning).codexAgentTheme(preset.theme), name: "reasoning-\(preset.rawValue)")
            try assertRenders(CodexPlanCard(plan: Self.plan).codexAgentTheme(preset.theme), name: "plan-\(preset.rawValue)")
            try assertRenders(CodexCompletedWorkTraceView(trace: Self.completedWorkTrace).codexAgentTheme(preset.theme), name: "work-trace-\(preset.rawValue)")
        }
    }

    private func assertRenders<Content: View>(_ view: Content, name: String) throws {
        let renderer = ImageRenderer(content: view.padding(24).frame(width: 760, alignment: .leading))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: 760, height: 360)
        let image = try XCTUnwrap(renderer.cgImage, "Expected \(name) to render a CGImage")
        XCTAssertGreaterThan(image.width, 0, name)
        XCTAssertGreaterThan(image.height, 0, name)
    }

    private static let commandRun = CodexChatMessage.CommandRun(
        itemID: "command-render",
        command: "swift test --filter CodexCardRenderingTests",
        cwd: "/tmp/CodexCore",
        output: "Build complete\nExecuted 1 test",
        status: "completed",
        exitCode: 0,
        isStreaming: false
    )

    private static let fileChange = CodexChatMessage.FileChange(
        itemID: "file-render",
        path: "Sources/CodexCoreUI/CodexCardRenderingTests.swift",
        kind: "update",
        diff: """
        diff --git a/Sources/file.swift b/Sources/file.swift
        --- a/Sources/file.swift
        +++ b/Sources/file.swift
        @@ -1,2 +1,2 @@
        -let old = true
        +let new = true
        """,
        status: "updated",
        isStreaming: false
    )

    private static let toolCall = CodexChatMessage.ToolCall(
        itemID: "tool-render",
        server: "github",
        tool: "create_pull_request",
        arguments: #"{"base":"main","head":"codex/example"}"#,
        status: "completed",
        progress: ["Validated branch", "Opened draft"],
        result: "https://github.com/slopwareinc/codexcore/pull/1",
        durationMilliseconds: 128,
        isStreaming: false
    )

    private static let notice = CodexChatMessage.Notice(
        itemID: "notice-render",
        kind: "model_warning",
        title: "Model switched",
        detail: "The selected model was adjusted for this turn.",
        status: "complete",
        metadata: ["from: gpt-5", "to: gpt-5.1"],
        severity: .warning
    )

    private static let reasoning = CodexChatMessage.ReasoningBlock(
        itemID: "reasoning-render",
        text: "Inspect repeated UI card shells, then extract a shared primitive.",
        isStreaming: false
    )

    private static let plan = CodexChatMessage.PlanUpdate(
        itemID: "plan-render",
        explanation: "Prepare the UI cleanup lane.",
        steps: [
            .init(step: "Extract cards", status: "completed"),
            .init(step: "Add rendering tests", status: "in_progress")
        ],
        isStreaming: false
    )

    private static let completedWorkTrace = CodexCompletedWorkTrace(
        id: "trace-render",
        title: "Worked for 1m 08s",
        groups: [
            .init(
                kind: .command,
                title: "Ran commands",
                operations: [
                    .init(
                        id: "command-render",
                        title: "swift test --filter CodexCardRenderingTests",
                        detail: "Build complete\nExecuted 1 test",
                        status: "exit 0",
                        isFailure: false,
                        message: CodexChatMessage(role: .terminal, text: "Build complete")
                    )
                ]
            )
        ],
        createdAt: Date(timeIntervalSince1970: 100)
    )
}
