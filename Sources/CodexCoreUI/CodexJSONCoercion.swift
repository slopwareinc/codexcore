import CodexCore

// `CodexJSONCoercion`, `String.nilIfEmpty`, and `String.nilIfBlank` now live in
// CodexCore (Protocol/CodexJSONCoercion.swift) so the SDK, UI, and host apps can
// share one implementation. The extensions below stay here because they operate
// on the UI-layer `CodexSubagentState` type.

extension CodexSubagentState.Status {
    init(normalizing rawStatus: String?, default fallback: Self = .running) {
        self = Self.normalized(rawStatus) ?? fallback
    }

    /// The canonical subagent-status synonym table. A `cancelled`/`canceled`
    /// subagent normalizes to `.closed` (deliberately stopped, not an error);
    /// only genuine error states map to `.failed`.
    static func normalized(_ rawStatus: String?) -> Self? {
        switch rawStatus?
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
        {
        case "running", "active", "inprogress", "in_progress":
            return .running
        case "completed", "complete", "done", "success", "succeeded":
            return .completed
        case "closed", "cancelled", "canceled", "skipped", "archived":
            return .closed
        case "failed", "failure", "error":
            return .failed
        default:
            return nil
        }
    }
}

extension CodexNotificationPayload {
    var normalizedKnownPayload: (method: CodexAppServerNotificationMethod, params: [String: CodexJSONValue])? {
        switch self {
        case .known(let method, let params):
            return (method, params)
        case .unknown(let rawMethod, let params):
            guard let method = CodexAppServerNotificationMethod(rawValue: rawMethod) else { return nil }
            return (method, params)
        default:
            return nil
        }
    }
}
