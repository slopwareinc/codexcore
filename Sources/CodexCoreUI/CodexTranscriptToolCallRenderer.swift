import SwiftUI

/// Customizes transcript rendering for dynamic and MCP tool calls.
///
/// Return a view to replace the default `CodexToolCallCard`, or `nil` to keep
/// CodexCoreUI's generic tool-call card for that tool call.
@MainActor
public struct CodexTranscriptToolCallRenderer {
    private let renderBody: (CodexChatMessage.ToolCall) -> AnyView?

    public init(_ renderBody: @escaping (CodexChatMessage.ToolCall) -> AnyView?) {
        self.renderBody = renderBody
    }

    public func render(_ toolCall: CodexChatMessage.ToolCall) -> AnyView? {
        renderBody(toolCall)
    }
}
