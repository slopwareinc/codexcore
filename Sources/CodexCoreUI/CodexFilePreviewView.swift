import AppKit
import CodexCore
import SwiftTreeSitter
import SwiftUI
import TreeSitterBash
import TreeSitterC
import TreeSitterGo
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterPython
import TreeSitterRuby
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTypeScript
import TreeSitterYAML

// MARK: - Highlight model

/// A resolved syntax-highlight span: a character range plus the coarse token
/// bucket it maps to. Value type so it can cross task boundaries freely.
struct CodexHighlightSpan: Sendable {
    let range: NSRange
    let kind: CodexTokenKind
}

/// Coarse token buckets we colour. Derived from tree-sitter capture names
/// (the first dotted component), kept deliberately small.
enum CodexTokenKind: Sendable {
    case keyword
    case string
    case comment
    case number
    case type
    case function
    case constant
    case property
    case variable
    case punctuation
    case attribute

    init?(captureName: String) {
        let root = captureName.split(separator: ".").first.map(String.init) ?? captureName
        switch root {
        case "keyword", "conditional", "repeat", "include", "operator":
            self = .keyword
        case "string", "character", "escape":
            self = .string
        case "comment":
            self = .comment
        case "number", "float", "boolean":
            self = .number
        case "type", "constructor":
            self = .type
        case "function", "method":
            self = .function
        case "constant":
            self = .constant
        case "property", "field":
            self = .property
        case "variable", "parameter":
            self = .variable
        case "punctuation", "delimiter", "bracket":
            self = .punctuation
        case "attribute", "annotation", "tag", "label":
            self = .attribute
        default:
            return nil
        }
    }
}

/// The rendered outcome of loading a file for preview. Sendable so a detached
/// loader can hand it back to the main actor.
enum CodexFilePreviewState: Sendable {
    case empty
    case loading
    case text(String, [CodexHighlightSpan])
    case notice(String)
}

// MARK: - Loader (runs off the main actor)

/// Loads and highlights a file. Every call is self-contained — it creates its
/// own tree-sitter parser/query locally and returns only `Sendable` values, so
/// it is safe to run from a detached task under strict concurrency.
enum CodexFilePreviewLoader {
    /// Hard cap on bytes we will read into memory for preview.
    static let maxByteSize = 2 * 1024 * 1024
    /// Only files at or below this size get syntax highlighting (parsing cost).
    static let maxHighlightBytes = 512 * 1024

    static func load(url: URL) -> CodexFilePreviewState {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true { return .empty }

        if let size = values?.fileSize, size > maxByteSize {
            let human = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            return .notice("File is too large to preview (\(human)).")
        }

        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return .notice("Unable to read this file.")
        }
        if isBinary(data) {
            return .notice("Binary file — no preview available.")
        }
        guard let text = decodeText(data) else {
            return .notice("Unable to decode this file as text.")
        }

        let spans = data.count <= maxHighlightBytes ? highlight(text: text, url: url) : []
        return .text(text, spans)
    }

    /// Heuristic binary check: a NUL byte in the first chunk means "not text".
    private static func isBinary(_ data: Data) -> Bool {
        data.prefix(8000).contains(0)
    }

    private static func decodeText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func highlight(text: String, url: URL) -> [CodexHighlightSpan] {
        guard let grammar = grammar(for: url) else { return [] }
        let language = Language(grammar.language)
        guard
            let queryURL = highlightsQueryURL(name: grammar.name),
            let query = try? language.query(contentsOf: queryURL)
        else {
            return []
        }

        let parser = Parser()
        guard (try? parser.setLanguage(language)) != nil, let tree = parser.parse(text) else {
            return []
        }

        let cursor = query.execute(in: tree)
        let named = cursor.resolve(with: .init(string: text)).highlights()
        return named.compactMap { range in
            guard let kind = CodexTokenKind(captureName: range.name) else { return nil }
            return CodexHighlightSpan(range: range.range, kind: kind)
        }
    }

    /// Locates a grammar's bundled `highlights.scm`. SwiftTreeSitter's built-in
    /// discovery assumes a packaged macOS bundle (`Contents/Resources/queries`),
    /// but command-line builds and test runs produce flat bundles (`queries/`).
    /// We search the plausible container directories and both layouts so
    /// highlighting works whether run from `.app`, `swift run`, or `swift test`.
    private static func highlightsQueryURL(name: String) -> URL? {
        let bundleName = "TreeSitter\(name)_TreeSitter\(name).bundle"
        let fileManager = FileManager.default

        var containers: [URL] = []
        func addContainers(from bundle: Bundle) {
            if let resourceURL = bundle.resourceURL { containers.append(resourceURL) }
            containers.append(bundle.bundleURL.deletingLastPathComponent())
            if let executableDir = bundle.executableURL?.deletingLastPathComponent() {
                containers.append(executableDir)
            }
        }
        addContainers(from: .main)
        Bundle.allBundles.forEach(addContainers)

        for container in containers {
            let bundleURL = container.appendingPathComponent(bundleName, isDirectory: true)
            for subpath in ["queries/highlights.scm", "Contents/Resources/queries/highlights.scm"] {
                let candidate = bundleURL.appendingPathComponent(subpath)
                if fileManager.isReadableFile(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    /// Maps a file extension to a bundled tree-sitter grammar. `name` must match
    /// the grammar package so `LanguageConfiguration` finds its query bundle.
    private static func grammar(for url: URL) -> (language: OpaquePointer, name: String)? {
        switch url.pathExtension.lowercased() {
        case "swift": return (tree_sitter_swift(), "Swift")
        case "json": return (tree_sitter_json(), "JSON")
        case "js", "jsx", "mjs", "cjs": return (tree_sitter_javascript(), "JavaScript")
        case "ts", "tsx", "mts", "cts": return (tree_sitter_typescript(), "TypeScript")
        case "py", "pyi": return (tree_sitter_python(), "Python")
        case "go": return (tree_sitter_go(), "Go")
        case "rs": return (tree_sitter_rust(), "Rust")
        case "sh", "bash", "zsh": return (tree_sitter_bash(), "Bash")
        case "rb": return (tree_sitter_ruby(), "Ruby")
        case "c", "h": return (tree_sitter_c(), "C")
        case "yml", "yaml": return (tree_sitter_yaml(), "YAML")
        default: return nil
        }
    }
}

// MARK: - Model

@MainActor
final class CodexFilePreviewModel: ObservableObject {
    @Published private(set) var state: CodexFilePreviewState = .empty

    private var currentURL: URL?
    private var loadTask: Task<Void, Never>?

    func update(url: URL?) {
        guard url != currentURL else { return }
        currentURL = url
        loadTask?.cancel()

        guard let url else {
            state = .empty
            return
        }

        state = .loading
        loadTask = Task { [url] in
            let result = await Task.detached(priority: .userInitiated) {
                CodexFilePreviewLoader.load(url: url)
            }.value
            guard !Task.isCancelled else { return }
            self.state = result
        }
    }
}

// MARK: - SwiftUI surface

struct CodexFilePreviewView: View {
    @Environment(\.codexAgentTheme) private var theme
    @StateObject private var model = CodexFilePreviewModel()

    let url: URL?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.colors.codeBackground)
            .onAppear { model.update(url: url) }
            .onChange(of: url) { _, newValue in model.update(url: newValue) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .empty:
            placeholder("Select a file to preview", symbol: "doc.text")
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .notice(message):
            placeholder(message, symbol: "doc.questionmark")
        case let .text(text, spans):
            CodexCodeTextView(text: text, spans: spans, theme: theme)
        }
    }

    private func placeholder(_ message: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(theme.fonts.heroTitle.weight(.regular))
                .foregroundStyle(theme.colors.textTertiary)
            Text(message)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Session

/// A single open file-preview tab in the workspace tool deck. Identity is the
/// file URL combined with an optional ref, so the same file at different refs
/// (e.g. working tree vs. a commit) each get their own unique tab.
@MainActor
public final class CodexFilePreviewSession: ObservableObject, Identifiable {
    public let id: String
    public let fileURL: URL
    public let ref: String?

    public init(fileURL: URL, ref: String? = nil) {
        let standardized = fileURL.standardizedFileURL
        self.fileURL = standardized
        self.ref = ref
        self.id = Self.identity(fileURL: standardized, ref: ref)
    }

    public var title: String {
        let name = fileURL.lastPathComponent
        guard let ref, !ref.isEmpty else { return name }
        return "\(name)@\(ref)"
    }

    /// Stable identity for a file/ref pair, so re-opening the same combination
    /// re-activates the existing tab instead of spawning a duplicate.
    public static func identity(fileURL: URL, ref: String?) -> String {
        "filepreview:\(ref ?? "")|\(fileURL.standardizedFileURL.path)"
    }
}

// MARK: - NSTextView bridge

private struct CodexCodeTextView: NSViewRepresentable {
    let text: String
    let spans: [CodexHighlightSpan]
    let theme: CodexAgentTheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.allowsUndo = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 4

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        apply(to: textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        apply(to: textView, coordinator: context.coordinator)
    }

    /// Rebuilds the attributed string only when the content actually changes,
    /// so routine SwiftUI updates don't re-lay-out the whole document.
    private func apply(to textView: NSTextView, coordinator: Coordinator) {
        let token = text.hashValue ^ (spans.count &* 2_654_435_761)
        guard coordinator.appliedToken != token else { return }
        coordinator.appliedToken = token

        let font = theme.fonts.codeNSFont ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor(theme.colors.codeText),
            ]
        )

        let length = (text as NSString).length
        for span in spans where span.range.location >= 0 && NSMaxRange(span.range) <= length {
            attributed.addAttribute(.foregroundColor, value: color(for: span.kind), range: span.range)
        }

        textView.textStorage?.setAttributedString(attributed)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    /// Maps token buckets onto existing theme tokens so colours stay coherent
    /// across every preset (dark, light, sepia, …) without a bespoke palette.
    private func color(for kind: CodexTokenKind) -> NSColor {
        let colors = theme.colors
        switch kind {
        case .keyword: return NSColor(colors.accent)
        case .string: return NSColor(colors.success)
        case .comment: return NSColor(colors.codeFaint)
        case .number, .constant: return NSColor(colors.warning)
        case .type: return NSColor(colors.tool)
        case .function: return NSColor(colors.running)
        case .attribute: return NSColor(colors.danger)
        case .property: return NSColor(colors.textSecondary)
        case .punctuation: return NSColor(colors.textTertiary)
        case .variable: return NSColor(colors.codeText)
        }
    }

    final class Coordinator {
        var appliedToken: Int?
    }
}
