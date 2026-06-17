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

    public func segmentAssistantText(_ text: String) -> [AssistantContentSegment] {
        let parsed = Self.assistantContentSegments(from: assistantRenderBlocks(text))
        return parsed.isEmpty ? [.markdown(text)] : parsed
    }

    public func normalizedAssistantMarkdown(_ text: String) -> String {
        let segments = segmentAssistantText(text)
        let fragments = segments.compactMap { segment -> String? in
            guard case .markdown(let content) = segment else { return nil }
            return content
        }
        let normalized = Self.combinedMarkdownFragments(fragments)
        return normalized.isEmpty ? text : normalized
    }

    public func containsMath(_ text: String) -> Bool {
        parser.containsMath(text)
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

    public static func segmentAssistantText(_ text: String) -> [AssistantContentSegment] {
        `default`.segmentAssistantText(text)
    }

    public static func normalizedAssistantMarkdown(_ text: String) -> String {
        `default`.normalizedAssistantMarkdown(text)
    }

    public static func containsMath(_ text: String) -> Bool {
        `default`.containsMath(text)
    }

    public static func parseToolCalls(text: String) -> [ToolCallCardModel] {
        `default`.parseToolCalls(text: text)
    }

    public static func parseCodeReview(text: String) -> ConversationCodeReviewData? {
        `default`.parseCodeReview(text: text)
    }

    public static let `default` = MessageContentBridge()

    private static func assistantContentSegments(from renderBlocks: [AssistantRenderBlock]) -> [AssistantContentSegment] {
        var segments: [AssistantContentSegment] = []

        for block in renderBlocks {
            switch block {
            case .markdown(let markdown):
                guard !markdown.isEmpty else { continue }
                segments.append(.markdown(markdown))
            case .codeBlock(let language, let code):
                segments.append(.markdown(fencedMarkdown(code: code, language: language)))
            case .inlineImage(let data):
                segments.append(.inlineImage(data))
            }
        }

        return segments.isEmpty ? [.markdown("")] : segments
    }

    private static func fencedMarkdown(code: String, language: String?) -> String {
        let trimmedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fenceHeader = trimmedLanguage.isEmpty ? "```" : "```\(trimmedLanguage)"
        return "\(fenceHeader)\n\(code)\n```"
    }

    private static func combinedMarkdownFragments(_ fragments: [String]) -> String {
        var combined = ""

        for fragment in fragments where !fragment.isEmpty {
            if combined.isEmpty {
                combined = fragment
                continue
            }

            if combined.hasSuffix("\n\n") || fragment.hasPrefix("\n\n") {
                combined += fragment
            } else if combined.hasSuffix("\n") || fragment.hasPrefix("\n") {
                combined += "\n" + fragment
            } else {
                combined += "\n\n" + fragment
            }
        }

        return combined
    }
}
