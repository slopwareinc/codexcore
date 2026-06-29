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

    // MARK: - Tool Calls Parsing

    public func parseToolCalls(text: String) -> [ToolCallCardModel] {
        ToolCallMarkdownParser().parse(text: text)
    }

}
