import CodexCore

extension CodexCoreAppModel {
    func startCodeReview(_ target: CodexReviewTarget) async {
        guard let codex, let threadID = currentThreadID else {
            activityLog.append(
                .notice,
                title: "Review unavailable",
                detail: "Start or select a chat before requesting an AI review."
            )
            return
        }
        activityLog.append(.turn, title: "Starting review", detail: target.title)
        do {
            _ = try await codex.perform(CodexRequest.reviewStart(.init(
                delivery: .inline,
                target: target.schemaValue,
                threadID: threadID
            )))
            activityLog.append(.turn, title: "Review started", detail: target.title)
        } catch {
            activityLog.append(
                .notice,
                title: "Review failed",
                detail: CodexErrorFormat.localizedDescription(error)
            )
        }
    }
}
