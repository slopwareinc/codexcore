import Foundation

// MARK: - Message Content Bridge (Swift Implementation)

public enum MessageContentBridge {
    public static func assistantRenderBlocks(_ text: String) -> [AssistantRenderBlock] {
        let parsed = store.extractRenderBlocks(text: text)
        return parsed.isEmpty ? [.markdown(text)] : parsed
    }

    public static func segmentAssistantText(_ text: String) -> [AssistantContentSegment] {
        let parsed = assistantContentSegments(from: assistantRenderBlocks(text))
        return parsed.isEmpty ? [.markdown(text)] : parsed
    }

    public static func normalizedAssistantMarkdown(_ text: String) -> String {
        let segments = segmentAssistantText(text)
        let fragments = segments.compactMap { segment -> String? in
            guard case .markdown(let content) = segment else { return nil }
            return content
        }
        let normalized = combinedMarkdownFragments(fragments)
        return normalized.isEmpty ? text : normalized
    }

    public static func containsMath(_ text: String) -> Bool {
        store.containsMath(text)
    }

    public static func parseToolCalls(text: String) -> [ToolCallCardModel] {
        store.parseToolCalls(text: text)
    }

    public static func parseCodeReview(text: String) -> ConversationCodeReviewData? {
        store.parseCodeReview(text: text)
    }

    private static let store = MessageParser()

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
