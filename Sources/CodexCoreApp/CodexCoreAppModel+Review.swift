import CodexCore

extension CodexCoreAppModel {
    func startCodeReview(_ target: CodexReviewTarget) async {
        guard let context = beginChatActionContext() else {
            return
        }
        do {
            _ = try await context.codex.perform(CodexRequest.reviewStart(.init(
                delivery: .inline,
                target: target.schemaValue,
                threadID: context.threadID
            )))
        } catch {
            reportChatActionFailure("Start review", error: error, context: context)
        }
    }
}
