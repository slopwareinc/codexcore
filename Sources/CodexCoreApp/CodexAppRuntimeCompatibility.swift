import CodexCore

enum CodexAppRuntimeCompatibility {
    /// The SDK retains its older core lifecycle floor; the reference app uses
    /// the complete generated feature stack and needs that runtime minor line.
    static func requireFeatureStack(_ warning: CodexRuntimeVersionWarning?) throws {
        guard let warning else { return }
        let actual = warning.actual.split(separator: " ").last?.split(separator: ".").prefix(2)
        let expected = CodexPinnedRuntime.version.split(separator: ".").prefix(2)
        guard actual?.elementsEqual(expected) == true else {
            throw CodexAppFeatureError.invalidInput(
                "The reference app requires Codex \(expected.joined(separator: ".")).x for its runtime features. Found \(warning.actual). Update the local Codex runtime and reconnect."
            )
        }
    }
}
