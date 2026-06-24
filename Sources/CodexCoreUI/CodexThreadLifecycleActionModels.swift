import Foundation

public enum CodexThreadLifecycleActionModel {
    public static func addAutomationDraftPrompt(
        threadID: String,
        threadTitle: String,
        workspacePath: String
    ) -> String {
        let normalizedTitle = threadTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = normalizedTitle.isEmpty ? "current chat" : normalizedTitle
        return """
        I want to set up an automation for the current chat "\(title)" (\(threadID)) in \(workspacePath). Ask me what should trigger it, what Codex should do, and how often it should run before changing any settings.
        """
    }

    public static func openInNewWindowUnavailableActivity(threadID: String) -> CodexActivity {
        CodexActivity(
            kind: .notice,
            title: "Open window unavailable",
            detail: "Native open-in-new-window is not wired for \(threadID) yet."
        )
    }
}
