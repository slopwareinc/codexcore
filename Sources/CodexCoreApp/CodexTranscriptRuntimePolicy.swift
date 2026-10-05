import CodexCore

/// Runtime requests that supply the app's checklist and reasoning timeline.
/// These stay in the reference host; SDK callers retain control of their params.
enum CodexTranscriptRuntimePolicy {
    // The checklist tool is opt-in in current Codex runtimes.
    static let threadConfig: CodexJSONValue = .dictionary([
        "tools.update_plan.enabled": .bool(true),
    ])

    // Codex omits this parameter at the model boundary when unsupported.
    static let reasoningSummary = CodexSchemaReasoningSummary(.string("detailed"))

    static func threadConfig(adding overrides: [String: CodexJSONValue]) -> CodexJSONValue {
        var config = threadConfig.objectValue ?? [:]
        config.merge(overrides) { _, override in override }
        return .dictionary(config)
    }
}
