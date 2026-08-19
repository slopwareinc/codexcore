import CodexCore

extension CodexCoreAppModel {
    func startCodeReview(_ target: CodexReviewTarget) async {
        guard let codex, let threadID = currentThreadID else {
            return
        }
        do {
            _ = try await codex.perform(CodexRequest.reviewStart(.init(
                delivery: .inline,
                target: target.schemaValue,
                threadID: threadID
            )))
        } catch {}
    }
}
