import Foundation

struct CodexProjectlessThreadPaths: Sendable, Equatable {
    let workspaceRoot: String
    let cwd: String
    let outputDirectory: String

    static func create(fileManager: FileManager = .default) throws -> Self {
        let documents = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        let root = documents
            .appendingPathComponent("Codex", isDirectory: true)
            .appendingPathComponent("Chats", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        return Self(
            workspaceRoot: root.path,
            cwd: work.path,
            outputDirectory: output.path
        )
    }

    init(workspaceRoot: String, cwd: String, outputDirectory: String) {
        self.workspaceRoot = workspaceRoot
        self.cwd = cwd
        self.outputDirectory = outputDirectory
    }

    init?(resumingCWD cwd: String?) {
        guard let cwd, !cwd.isEmpty else { return nil }
        let cwdURL = URL(fileURLWithPath: cwd)
        if cwdURL.lastPathComponent == "work" {
            let root = cwdURL.deletingLastPathComponent()
            self.init(
                workspaceRoot: root.path,
                cwd: cwdURL.path,
                outputDirectory: root.appendingPathComponent("output", isDirectory: true).path
            )
        } else {
            self.init(
                workspaceRoot: cwdURL.path,
                cwd: cwdURL.path,
                outputDirectory: cwdURL.path
            )
        }
    }

    var developerInstructions: String {
        """
        ### Projectless Chat
        This projectless thread starts in a generated directory under the user's Documents/Codex folder.
        Prefer answering inline in chat unless using local files would make the result more useful.
        Use work/ for intermediate files, scratch analysis, scripts, drafts, and temporary assets.
        Save user-facing deliverables under \(outputDirectory).
        When referring to saved deliverables in the final response, link only files from \(outputDirectory).
        Do not write directly in the home directory unless the user explicitly asks.
        """
    }
}
