import CodexCore

/// Captures the owner before an action suspends, so late failures cannot
/// replace feedback for another chat or account.
@MainActor
struct CodexChatActionContext {
    let codex: Codex
    let threadID: String
    let accountRevision: Int
    let selectionGeneration: Int
    let feedbackRevision: UInt64
}
