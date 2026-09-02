import CodexCore
import Foundation

enum CodexBuiltInVisualizationSkill {
    static let version = 2
    static let contents = """
    ---
    name: visualize
    description: Create visualizations and interactive tools directly in conversation. Proactively use them to explain behavior, compare, inspect, simulate, map, chart, or mock up an interface when a visual materially improves the answer.
    ---

    <!-- codexcore-bundled-visualize:v\(version) -->

    # Visualize

    A project file, site, app page, or component is not an in-conversation
    visualization. Use a Markdown table for a table and Mermaid for a static
    node-and-edge diagram. Use this skill for dynamics, spatial motion,
    adjustable inputs, simulations, and interface previews.

    ## Inline output contract

    - Create one concise lowercase-hyphenated `.html` file in an explicitly
      writable, durable, task-owned visualization root. Use its absolute path.
    - Write an HTML fragment only: no doctype, html, head, or body wrapper.
      Keep literal CSS and JavaScript in the fragment and keep it below 1 MB.
    - Never use fetch, XHR, WebSocket, navigation, forms, external frames, or
      persistent storage. Static CDN resources must use the host allowlist.
    - Give interactive controls accessible labels. Verify queried elements and
      the primary interaction before responding.
    - For a drill-down that asks Codex to investigate selected data, call
      `await window.openai.sendFollowUpMessage({ prompt, title })`. The host
      always asks the user to confirm before sending it.
    - In the same final response, put this reference alone where it should render:

       `visualize{"path":"/absolute/path/to/title.html"}`

    The object may include `"title"`. Add `"mode":"wide"` only when multiple
    compact panels must remain side by side; wide content is still inline and
    expandable. Always emit the reference after creating or updating a visual.
    Never substitute a Markdown link or describe the fragment as a file,
    artifact, website, attachment, or download.
    """

    @concurrent
    nonisolated static func install(in codexHome: CodexHome) async throws {
        let directory = codexHome.directoryURL
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("visualize", isDirectory: true)
        let destination = directory.appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if let existing = try? String(contentsOf: destination, encoding: .utf8),
           !existing.contains("codexcore-bundled-visualize:") {
            // Never overwrite a user-authored skill. The only marker-less file
            // eligible for migration is the short v1 skill shipped by this app.
            guard existing.contains("$CODEX_HOME/visualizations"),
                  existing.contains("visualize") else { return }
        }
        try Data(contents.utf8).write(to: destination, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
    }
}
