import Foundation

// MARK: - Message Parser (Swift Implementation)

public final class MessageParser: Sendable {
    public init() {}

    // MARK: - Render Block Extraction

    public func extractRenderBlocks(text: String) -> [AssistantRenderBlock] {
        AssistantRenderBlockParser().extractRenderBlocks(text: text)
    }

    // MARK: - Code Review Parsing

    public func parseCodeReview(text: String) -> ConversationCodeReviewData? {
        CodeReviewPayloadParser.parse(text: text)
    }

    // Tool-call card parsing moved to CodexCoreUI (CodexToolCallCardParser).
}
