import Foundation

public struct CodexComposerDictationButtonState: Equatable, Sendable {
    public var title: String
    public var systemImage: String
    public var accessibilityLabel: String
    public var help: String
    public var isEnabled: Bool

    public init(
        title: String,
        systemImage: String,
        accessibilityLabel: String,
        help: String,
        isEnabled: Bool
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.help = help
        self.isEnabled = isEnabled
    }
}

public struct CodexComposerDictationRoute: Equatable, Sendable {
    public var activities: [CodexActivity]
    public var noticeMessage: CodexChatMessage

    public init(activities: [CodexActivity], noticeMessage: CodexChatMessage) {
        self.activities = activities
        self.noticeMessage = noticeMessage
    }
}

public enum CodexComposerDictationModel {
    public static let buttonState = CodexComposerDictationButtonState(
        title: "Dictate",
        systemImage: "mic",
        accessibilityLabel: "Dictate",
        help: "Dictate",
        isEnabled: true
    )

    public static func route() -> CodexComposerDictationRoute {
        let detail = "Native dictation and microphone permission handling are not wired in this composer yet."
        let notice = CodexChatMessage.Notice(
            itemID: "composer-dictation-unavailable",
            kind: "composer.dictation.unavailable",
            title: "Dictation unavailable",
            detail: detail,
            severity: .warning
        )
        return CodexComposerDictationRoute(
            activities: [
                CodexActivity(
                    kind: .notice,
                    title: notice.title,
                    detail: notice.detail
                )
            ],
            noticeMessage: CodexChatMessage(
                role: .notice,
                text: notice.copyText,
                notice: notice
            )
        )
    }
}
