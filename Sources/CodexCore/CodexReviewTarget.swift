import Foundation

/// Strongly typed targets for the app-server `review/start` workflow.
public enum CodexReviewTarget: Sendable, Equatable {
    case uncommittedChanges
    case baseBranch(String)
    case commit(sha: String, title: String? = nil)
    case custom(String)

    public var title: String {
        switch self {
        case .uncommittedChanges: "Uncommitted changes"
        case .baseBranch(let branch): "Changes from \(branch)"
        case .commit(_, let title):
            if let title,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                title
            } else {
                "Commit"
            }
        case .custom: "Custom review"
        }
    }

    public var schemaValue: CodexSchemaReviewTarget {
        switch self {
        case .uncommittedChanges:
            CodexSchemaReviewTarget(.dictionary([
                "type": .string("uncommittedChanges"),
            ]))
        case .baseBranch(let branch):
            CodexSchemaReviewTarget(.dictionary([
                "type": .string("baseBranch"),
                "branch": .string(branch),
            ]))
        case .commit(let sha, let title):
            CodexSchemaReviewTarget(.dictionary([
                "type": .string("commit"),
                "sha": .string(sha),
                "title": title.map(CodexJSONValue.string) ?? .null,
            ]))
        case .custom(let instructions):
            CodexSchemaReviewTarget(.dictionary([
                "type": .string("custom"),
                "instructions": .string(instructions),
            ]))
        }
    }
}
