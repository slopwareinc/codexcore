import Foundation

// MARK: - Message Content Bridge (Swift Implementation)

public struct MessageContentBridge: Sendable {
    private let parser: MessageParser

    public init(parser: MessageParser = MessageParser()) {
        self.parser = parser
    }

    public func assistantRenderBlocks(_ text: String) -> [AssistantRenderBlock] {
        let parsed = parser.extractRenderBlocks(text: text)
        return parsed.isEmpty ? [.markdown(text)] : parsed
    }

    public func parseToolCalls(text: String) -> [ToolCallCardModel] {
        parser.parseToolCalls(text: text)
    }

    public func parseCodeReview(text: String) -> ConversationCodeReviewData? {
        parser.parseCodeReview(text: text)
    }

    public static func assistantRenderBlocks(_ text: String) -> [AssistantRenderBlock] {
        `default`.assistantRenderBlocks(text)
    }

    public static func parseToolCalls(text: String) -> [ToolCallCardModel] {
        `default`.parseToolCalls(text: text)
    }

    public static func parseCodeReview(text: String) -> ConversationCodeReviewData? {
        `default`.parseCodeReview(text: text)
    }

    public static let `default` = MessageContentBridge()
}
