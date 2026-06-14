import Foundation
import CodexCore

public struct CodexFileChangeUndoPlan: Equatable, Sendable {
    public var command: [String]
    public var cwd: String
    public var relativePath: String

    public init(command: [String], cwd: String, relativePath: String) {
        self.command = command
        self.cwd = cwd
        self.relativePath = relativePath
    }
}

public enum CodexFileChangeUndoSession {
    public static func plan(
        for change: CodexChatMessage.FileChange,
        workspacePath: String
    ) -> CodexFileChangeUndoPlan? {
        guard let relativePath = relativePath(for: change, workspacePath: workspacePath) else {
            return nil
        }
        let command: [String]
        if isAddition(change) {
            command = ["git", "clean", "-f", "--", relativePath]
        } else {
            command = ["git", "checkout", "--", relativePath]
        }
        return CodexFileChangeUndoPlan(command: command, cwd: workspacePath, relativePath: relativePath)
    }

    public static var unavailableActivity: CodexActivity {
        CodexActivity(kind: .notice, title: "Undo unavailable", detail: "No file path to revert")
    }

    public static func successActivity(relativePath: String) -> CodexActivity {
        CodexActivity(kind: .notice, title: "Reverted", detail: relativePath)
    }

    public static func failureActivity(message: String) -> CodexActivity {
        CodexActivity(kind: .notice, title: "Undo failed", detail: message)
    }

    private static func relativePath(
        for change: CodexChatMessage.FileChange,
        workspacePath: String
    ) -> String? {
        guard let path = change.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        let root = workspacePath.hasSuffix("/") ? workspacePath : workspacePath + "/"
        if path.hasPrefix(root) {
            return String(path.dropFirst(root.count))
        }
        return path
    }

    private static func isAddition(_ change: CodexChatMessage.FileChange) -> Bool {
        let kind = change.kind.lowercased()
        return kind.contains("add") || kind.contains("create")
    }
}
