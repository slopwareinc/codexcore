import Foundation

// MARK: - Models & Enums

public enum AssistantRenderBlock: Equatable, Sendable {
    case markdown(String)
    case codeBlock(language: String?, code: String)
    case inlineImage(Data)
}

public enum AssistantContentSegment: Equatable, Sendable {
    case markdown(String)
    case inlineImage(Data)
}

// Tool-call *card* presentation models (ToolCallKind/Status/Section/CardModel)
// moved to CodexCoreUI (CodexToolCallCardModel.swift) — they carry SF Symbol
// names, human titles/labels, formatted durations, and disclosure state.

public struct ConversationCodeReviewLineRange: Codable, Sendable, Equatable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

public struct ConversationCodeReviewLocation: Codable, Sendable, Equatable {
    public let absoluteFilePath: String
    public let lineRange: ConversationCodeReviewLineRange?

    public init(absoluteFilePath: String, lineRange: ConversationCodeReviewLineRange?) {
        self.absoluteFilePath = absoluteFilePath
        self.lineRange = lineRange
    }
}

public struct ConversationCodeReviewFinding: Codable, Sendable, Equatable {
    public let title: String
    public let body: String
    public let confidenceScore: Double
    public let priority: Int?
    public let codeLocation: ConversationCodeReviewLocation?

    public init(title: String, body: String, confidenceScore: Double, priority: Int?, codeLocation: ConversationCodeReviewLocation?) {
        self.title = title
        self.body = body
        self.confidenceScore = confidenceScore
        self.priority = priority
        self.codeLocation = codeLocation
    }
}

public struct ConversationCodeReviewData: Codable, Sendable, Equatable {
    public let findings: [ConversationCodeReviewFinding]
    public let overallCorrectness: String?
    public let overallExplanation: String?
    public let overallConfidenceScore: Double?

    public init(findings: [ConversationCodeReviewFinding], overallCorrectness: String?, overallExplanation: String?, overallConfidenceScore: Double?) {
        self.findings = findings
        self.overallCorrectness = overallCorrectness
        self.overallExplanation = overallExplanation
        self.overallConfidenceScore = overallConfidenceScore
    }
}

