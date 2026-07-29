import CodexCore

extension CodexCoreAppModel {
    func startCodeReview(_ target: CodexReviewTarget) async {
        guard let codex, let threadID = currentThreadID else {
            appendActivity(
                .notice,
                title: "Review unavailable",
                detail: "Start or select a chat before requesting an AI review."
            )
            return
        }
        appendActivity(.turn, title: "Starting review", detail: target.title)
        do {
            _ = try await codex.perform(CodexRequest.reviewStart(.init(
                delivery: .inline,
                target: target.schemaValue,
                threadID: threadID
            )))
            appendActivity(.turn, title: "Review started", detail: target.title)
        } catch {
            appendActivity(
                .notice,
                title: "Review failed",
                detail: friendlyError(error)
            )
        }
    }
}
