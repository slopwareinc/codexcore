import AppKit
import CodexCore
import SwiftUI

public enum CodexFileTreeNodeKind: Equatable, Sendable {
    case directory
    case file
    case symbolicLink
}

public final class CodexFileTreeNode: Identifiable {
    public let id: URL
    public let url: URL
    public let name: String
    public let kind: CodexFileTreeNodeKind
    public private(set) var children: [CodexFileTreeNode]?

    public init(url: URL, name: String? = nil, kind: CodexFileTreeNodeKind) {
        self.url = url
        self.id = url
        self.name = name ?? CodexFilesPathFormatter.rootName(for: url)
        self.kind = kind
    }

    public var isExpandable: Bool {
        kind == .directory
    }

    public var areChildrenLoaded: Bool {
        children != nil
    }

    @discardableResult
    public func loadChildren(using loader: CodexFileTreeLoader = CodexFileTreeLoader()) -> [CodexFileTreeNode] {
        guard isExpandable else { return [] }
        if let children { return children }
        let loadedChildren = loader.children(of: url)
        children = loadedChildren
        return loadedChildren
    }

    public func invalidateChildren() {
        children = nil
    }

    func setLoadedChildren(_ children: [CodexFileTreeNode]) {
        self.children = children
    }
}

public struct CodexFileTreeLoader {
    public static let ignoredDirectoryNames: Set<String> = [
        ".build",
        ".git",
        ".swiftpm",
        "DerivedData",
        "node_modules",
    ]

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func rootNode(for rootURL: URL) -> CodexFileTreeNode {
        CodexFileTreeNode(url: rootURL.standardizedFileURL, kind: .directory)
    }

    public func children(of directoryURL: URL) -> [CodexFileTreeNode] {
        entries(of: directoryURL).map(makeNode)
    }

    /// Performs directory enumeration away from the main actor. The outline
    /// view asks its data source for children synchronously, so callers use the
    /// returned entries to populate nodes only after the I/O has completed.
    static func childrenAsync(of directoryURL: URL) async -> [CodexFileTreeEntry] {
        await Task.detached(priority: .utility) {
            CodexFileTreeLoader().entries(of: directoryURL)
        }.value
    }

    private func entries(of directoryURL: URL) -> [CodexFileTreeEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .localizedNameKey]
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants]
            )
        } catch {
            return []
        }

        return urls.compactMap { fileTreeEntry(for: $0, resourceKeys: keys) }
        .sorted(by: Self.sortNodes)
    }

    private func fileTreeEntry(for url: URL, resourceKeys: Set<URLResourceKey>) -> CodexFileTreeEntry? {
        let values = try? url.resourceValues(forKeys: resourceKeys)
        let name = values?.localizedName ?? url.lastPathComponent
        let isDirectory = values?.isDirectory == true

        guard !(isDirectory && Self.ignoredDirectoryNames.contains(name)) else {
            return nil
        }

        let kind: CodexFileTreeNodeKind
        if values?.isSymbolicLink == true {
            kind = .symbolicLink
        } else if isDirectory {
            kind = .directory
        } else {
            kind = .file
        }

        return CodexFileTreeEntry(url: url.standardizedFileURL, name: name, kind: kind)
    }

    public static func sortNodes(_ lhs: CodexFileTreeNode, _ rhs: CodexFileTreeNode) -> Bool {
        if lhs.kind == .directory, rhs.kind != .directory { return true }
        if lhs.kind != .directory, rhs.kind == .directory { return false }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func sortNodes(_ lhs: CodexFileTreeEntry, _ rhs: CodexFileTreeEntry) -> Bool {
        if lhs.kind == .directory, rhs.kind != .directory { return true }
        if lhs.kind != .directory, rhs.kind == .directory { return false }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private func makeNode(_ entry: CodexFileTreeEntry) -> CodexFileTreeNode {
        CodexFileTreeNode(url: entry.url, name: entry.name, kind: entry.kind)
    }
}

struct CodexFileTreeEntry: Sendable {
    let url: URL
    let name: String
    let kind: CodexFileTreeNodeKind
}

public enum CodexFilesPathFormatter {
    public static func rootName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    public static func display(_ url: URL) -> String {
        CodexPathFormatter.abbreviatingHome(url.standardizedFileURL.path)
    }
}

@MainActor
public final class CodexFilesSession: ObservableObject, Identifiable {
    public let id: String
    public let title: String
    public let rootURL: URL
    @Published public var selectedURL: URL?
    @Published public private(set) var refreshIdentity: UUID
    @Published public private(set) var rootNode: CodexFileTreeNode

    private let loader: CodexFileTreeLoader

    public init(
        id: String = "files:\(UUID().uuidString)",
        title: String = "Files",
        rootURL: URL,
        loader: CodexFileTreeLoader = CodexFileTreeLoader()
    ) {
        self.id = id
        self.title = title
        self.rootURL = rootURL.standardizedFileURL
        self.loader = loader
        self.refreshIdentity = UUID()
        self.rootNode = loader.rootNode(for: rootURL)
    }

    public func refresh() {
        rootNode = loader.rootNode(for: rootURL)
        refreshIdentity = UUID()
    }
}

public struct CodexFilesToolView: View {
    @Environment(\.codexAgentTheme) private var theme
    @ObservedObject private var session: CodexFilesSession
    private let onOpenFile: (URL) -> Void

    public init(session: CodexFilesSession, onOpenFile: @escaping (URL) -> Void = { _ in }) {
        self.session = session
        self.onOpenFile = onOpenFile
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.colors.border)
            outline
        }
        // Selecting a file opens it as an independent preview tab in the deck.
        .onChange(of: session.selectedURL) { _, newValue in
            guard let url = newValue, isPreviewableFile(url) else { return }
            onOpenFile(url)
        }
    }

    private var outline: some View {
        CodexFilesOutlineView(
            rootNode: session.rootNode,
            selectedURL: $session.selectedURL,
            refreshIdentity: session.refreshIdentity
        )
        .background(theme.colors.surfaceSunken.opacity(0.8))
        .accessibilityLabel("Files")
    }

    /// Whether `url` points at a regular file worth opening in a preview tab.
    private func isPreviewableFile(_ url: URL) -> Bool {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        return !isDirectory
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textTertiary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(CodexFilesPathFormatter.rootName(for: session.rootURL))
                    .font(theme.fonts.label)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)

                Text(CodexFilesPathFormatter.display(session.rootURL))
                    .font(theme.fonts.micro)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Button(action: session.refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                    .frame(width: theme.spacing.iconLarge, height: theme.spacing.iconLarge)
            }
            .buttonStyle(.plain)
            .help("Refresh files")
            .accessibilityLabel("Refresh files")
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }
}

private struct CodexFilesOutlineView: NSViewRepresentable {
    let rootNode: CodexFileTreeNode
    @Binding var selectedURL: URL?
    let refreshIdentity: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedURL: $selectedURL, rootNode: rootNode, refreshIdentity: refreshIdentity)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = NSOutlineView()
        let column = NSTableColumn(identifier: Coordinator.columnIdentifier)
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .small
        outlineView.allowsMultipleSelection = false
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.style = .sourceList
        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        outlineView.target = context.coordinator
        outlineView.doubleAction = #selector(Coordinator.doubleClick(_:))

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = outlineView

        context.coordinator.outlineView = outlineView
        outlineView.reloadData()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let outlineView = scrollView.documentView as? NSOutlineView else { return }
        context.coordinator.selectedURL = $selectedURL
        let shouldReload = context.coordinator.rootNode !== rootNode || context.coordinator.refreshIdentity != refreshIdentity
        context.coordinator.rootNode = rootNode
        context.coordinator.refreshIdentity = refreshIdentity
        if shouldReload {
            context.coordinator.cancelPendingLoads()
            outlineView.reloadData()
        }
        context.coordinator.selectVisibleURL(selectedURL, in: outlineView)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        static let columnIdentifier = NSUserInterfaceItemIdentifier("CodexFilesColumn")
        private static let cellIdentifier = NSUserInterfaceItemIdentifier("CodexFilesCell")

        var selectedURL: Binding<URL?>
        var rootNode: CodexFileTreeNode
        var refreshIdentity: UUID
        weak var outlineView: NSOutlineView?
        private var isUpdatingSelection = false
        private var childLoadTasks: [URL: Task<Void, Never>] = [:]
        private var pendingExpansions: Set<URL> = []

        init(selectedURL: Binding<URL?>, rootNode: CodexFileTreeNode, refreshIdentity: UUID) {
            self.selectedURL = selectedURL
            self.rootNode = rootNode
            self.refreshIdentity = refreshIdentity
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            let node = node(for: item)
            guard let children = node.children else {
                requestChildren(for: node, in: outlineView, expandWhenLoaded: false)
                return 0
            }
            return children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            node(for: item).children?[index] ?? node(for: item)
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? CodexFileTreeNode else { return false }
            return node.isExpandable
        }

        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            guard let node = item as? CodexFileTreeNode, node.isExpandable else { return false }
            guard node.areChildrenLoaded else {
                pendingExpansions.insert(node.id)
                requestChildren(for: node, in: outlineView, expandWhenLoaded: true)
                return false
            }
            return true
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? CodexFileTreeNode else { return nil }
            let cell = outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? CodexFilesOutlineCell
                ?? CodexFilesOutlineCell(identifier: Self.cellIdentifier)
            cell.configure(with: node)
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdatingSelection, let outlineView = notification.object as? NSOutlineView else { return }
            let row = outlineView.selectedRow
            guard row >= 0, let node = outlineView.item(atRow: row) as? CodexFileTreeNode else {
                selectedURL.wrappedValue = nil
                return
            }
            selectedURL.wrappedValue = node.url
        }

        @objc func doubleClick(_ sender: Any?) {}

        func selectVisibleURL(_ url: URL?, in outlineView: NSOutlineView) {
            guard let url else { return }
            for row in 0..<outlineView.numberOfRows {
                guard let node = outlineView.item(atRow: row) as? CodexFileTreeNode, node.url == url else {
                    continue
                }
                guard outlineView.selectedRow != row else { return }
                isUpdatingSelection = true
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                isUpdatingSelection = false
                return
            }
        }

        private func node(for item: Any?) -> CodexFileTreeNode {
            (item as? CodexFileTreeNode) ?? rootNode
        }

        private func requestChildren(
            for node: CodexFileTreeNode,
            in outlineView: NSOutlineView,
            expandWhenLoaded: Bool
        ) {
            if expandWhenLoaded {
                pendingExpansions.insert(node.id)
            }
            guard childLoadTasks[node.id] == nil else { return }
            let expectedRefreshIdentity = refreshIdentity
            childLoadTasks[node.id] = Task { [weak self, node] in
                let entries = await CodexFileTreeLoader.childrenAsync(of: node.url)
                guard !Task.isCancelled else { return }
                guard let self, self.refreshIdentity == expectedRefreshIdentity else { return }
                node.setLoadedChildren(entries.map {
                    CodexFileTreeNode(url: $0.url, name: $0.name, kind: $0.kind)
                })
                self.childLoadTasks[node.id] = nil
                let shouldExpand = self.pendingExpansions.remove(node.id) != nil
                if node === self.rootNode {
                    outlineView.reloadData()
                } else {
                    outlineView.reloadItem(node, reloadChildren: true)
                }
                if shouldExpand {
                    outlineView.expandItem(node)
                }
            }
        }

        func cancelPendingLoads() {
            for task in childLoadTasks.values {
                task.cancel()
            }
            childLoadTasks.removeAll(keepingCapacity: true)
            pendingExpansions.removeAll(keepingCapacity: true)
        }
    }
}

private final class CodexFilesOutlineCell: NSTableCellView {
    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(with node: CodexFileTreeNode) {
        iconView.image = NSImage(systemSymbolName: systemImageName(for: node), accessibilityDescription: nil)
        iconView.contentTintColor = iconColor(for: node)
        nameField.stringValue = node.name
        nameField.textColor = node.kind == .symbolicLink ? .secondaryLabelColor : .labelColor
    }

    private func setup() {
        wantsLayer = true
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [iconView, nameField])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func systemImageName(for node: CodexFileTreeNode) -> String {
        switch node.kind {
        case .directory:
            return "folder"
        case .file:
            return "doc"
        case .symbolicLink:
            return "link"
        }
    }

    private func iconColor(for node: CodexFileTreeNode) -> NSColor {
        switch node.kind {
        case .directory:
            return .systemBlue
        case .file:
            return .secondaryLabelColor
        case .symbolicLink:
            return .tertiaryLabelColor
        }
    }
}
