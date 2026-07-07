import SwiftUI
import XCTest
@testable import CodexCoreUI

@MainActor
final class CodexTranscriptToolCallRendererTests: XCTestCase {
    func testDefaultToolCallRenderingUsesGenericCard() throws {
        let image = try renderToolMessage(
            toolCall(server: "github", tool: "create_pull_request"),
            renderer: nil
        )

        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
    }

    func testCustomRendererIsInvokedForWalkableTool() throws {
        var invokedTools: [String] = []
        let renderer = CodexTranscriptToolCallRenderer { toolCall in
            invokedTools.append(toolCall.displayName)
            guard toolCall.displayName == "walkable.create_project" else { return nil }
            return AnyView(
                Text("Walkable project card")
                    .padding(12)
                    .frame(width: 260, alignment: .leading)
            )
        }

        let image = try renderToolMessage(
            toolCall(tool: "walkable.create_project"),
            renderer: renderer
        )

        XCTAssertTrue(invokedTools.contains("walkable.create_project"))
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
    }

    func testRendererNilFallsBackForNonWalkableTool() throws {
        var invokedTools: [String] = []
        let renderer = CodexTranscriptToolCallRenderer { toolCall in
            invokedTools.append(toolCall.displayName)
            guard toolCall.displayName.hasPrefix("walkable.") else { return nil }
            return AnyView(Text("Walkable card"))
        }

        let image = try renderToolMessage(
            toolCall(server: "filesystem", tool: "read_file"),
            renderer: renderer
        )

        XCTAssertTrue(invokedTools.contains("filesystem.read_file"))
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
    }

    private func renderToolMessage(
        _ toolCall: CodexChatMessage.ToolCall,
        renderer: CodexTranscriptToolCallRenderer?
    ) throws -> CGImage {
        let message = CodexChatMessage(
            role: .tool,
            text: toolCall.displayName,
            createdAt: Date(timeIntervalSince1970: 100),
            toolCall: toolCall
        )
        let view = CodexMessageRow(message: message, toolCallRenderer: renderer)
            .padding(24)
            .frame(width: 760, alignment: .leading)
        let imageRenderer = ImageRenderer(content: view)
        imageRenderer.scale = 1
        imageRenderer.proposedSize = ProposedViewSize(width: 760, height: 220)
        return try XCTUnwrap(imageRenderer.cgImage)
    }

    private func toolCall(
        server: String? = nil,
        tool: String
    ) -> CodexChatMessage.ToolCall {
        CodexChatMessage.ToolCall(
            itemID: tool,
            server: server,
            tool: tool,
            arguments: #"{"id":"demo"}"#,
            status: "completed",
            progress: ["Prepared \(tool)"],
            result: "done",
            durationMilliseconds: 42,
            isStreaming: false
        )
    }
}
