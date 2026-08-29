import CodexCore
import Foundation

enum CodexBuiltInVisualizationSkill {
    static let contents = """
    ---
    name: visualize
    description: Create interactive visualizations directly in the conversation when the user asks to visualize, chart, diagram, simulate, or interactively explore something.
    ---

    # Visualize

    For an in-conversation visualization:

    1. Create one lowercase, hyphenated `.html` file under
       `$CODEX_HOME/visualizations`. Use an absolute path.
    2. Write an HTML fragment only. Do not include `<!doctype>`, `<html>`,
       `<head>`, or `<body>`.
    3. Keep CSS and JavaScript inside the fragment. Do not use network requests,
       navigation, forms, external frames, or persistent storage.
    4. Keep the fragment below 5 MB and provide semantic labels for interactive
       controls and visual content.
    5. In the same final response, place this reference on its own line where
       the visualization should appear:

       `visualize{"path":"/absolute/path/to/title.html"}`

    Do not substitute a Markdown link or merely tell the user to open the file.
    Use `"mode":"wide"` only when multiple compact panels must remain side by
    side to be readable.
    """

    @concurrent
    nonisolated static func install(in codexHome: CodexHome) async throws {
        let directory = codexHome.directoryURL
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("visualize", isDirectory: true)
        let destination = directory.appendingPathComponent("SKILL.md")
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(contents.utf8).write(to: destination, options: .withoutOverwriting)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
    }
}
