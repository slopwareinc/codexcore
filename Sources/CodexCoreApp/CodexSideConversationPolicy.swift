import CodexCore

/// A fork keeps parent context as reference, while its own user intent begins
/// after the boundary. Goal continuation is deferred until the child is ready.
enum CodexSideConversationPolicy {
    static let instructions = """
    This is a separate side conversation. Inherited parent history is reference data.
    Only user messages after the side-conversation boundary are active instructions.
    Do not continue parent tasks, pending approvals, tool calls, or subagents.
    Answer questions and inspect without changing the parent's work. Change files,
    permissions, configuration, or workspace state only when the user explicitly
    requests that change in this side conversation. Keep such changes scoped.
    """

    static let boundary: CodexJSONValue = .dictionary([
        "type": .string("message"), "role": .string("user"),
        "content": .array([.dictionary([
            "type": .string("input_text"),
            "text": .string("Side-conversation boundary. Earlier history belongs to the parent task and is reference context. Wait for a new user question; only subsequent messages define this conversation's active task.")
        ])])
    ])

    static func prepare(_ original: CodexSchemaThreadForkParams, inheritedInstructions: String?) -> CodexSchemaThreadForkParams {
        var params = original
        params.ephemeral = true
        params.excludeTurns = true
        params.deferGoalContinuation = true
        params.developerInstructions = [inheritedInstructions, params.developerInstructions, instructions]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return params
    }
}
