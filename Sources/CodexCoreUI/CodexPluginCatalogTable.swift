#if canImport(AppKit)
import AppKit
import SwiftUI

enum CodexPluginLayoutMetrics {
    static let contentWidth: CGFloat = 736
    static let rowHeight: CGFloat = 64
    static let rowSpacing: CGFloat = 8
}

struct CodexPluginCatalogTable: NSViewRepresentable {
    let plugins: [CodexPluginSummary]
    @Binding var selectedPluginID: String?
    let showsToggle: Bool
    let pendingPluginIDs: Set<String>
    let theme: CodexAgentTheme
    let onAction: (CodexPluginRouteAction) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.rowHeight = CodexPluginLayoutMetrics.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: CodexPluginLayoutMetrics.rowSpacing)
        table.addTableColumn(NSTableColumn(identifier: .init("plugin")))
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.setAccessibilityLabel("Plugin marketplace")

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        context.coordinator.tableView = table
        context.coordinator.apply(parent: self, forceReload: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.apply(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: CodexPluginCatalogTable
        weak var tableView: NSTableView?
        private var contentSignature = 0
        private var selectedID: String?

        init(parent: CodexPluginCatalogTable) {
            self.parent = parent
        }

        func apply(parent: CodexPluginCatalogTable, forceReload: Bool = false) {
            self.parent = parent
            let signature = Self.signature(
                for: parent.plugins,
                showsToggle: parent.showsToggle,
                pendingPluginIDs: parent.pendingPluginIDs
            )
            let contentChanged = forceReload || signature != contentSignature
            let selectionChanged = selectedID != parent.selectedPluginID
            contentSignature = signature
            selectedID = parent.selectedPluginID

            if contentChanged {
                tableView?.reloadData()
            } else if selectionChanged {
                tableView?.reloadData(forRowIndexes: tableView?.rows(in: tableView?.visibleRect ?? .zero).indexSet ?? [], columnIndexes: IndexSet(integer: 0))
            }
            synchronizeSelection()
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.plugins.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.plugins.indices.contains(row) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("CodexPluginCatalogCell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? CodexPluginCatalogCell)
                ?? CodexPluginCatalogCell(identifier: identifier)
            let plugin = parent.plugins[row]
            cell.configure(
                plugin: plugin,
                selected: plugin.id == parent.selectedPluginID,
                showsToggle: parent.showsToggle,
                isPending: parent.pendingPluginIDs.contains(plugin.protocolID),
                theme: parent.theme,
                onAction: parent.onAction
            )
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView, tableView.selectedRow >= 0,
                  parent.plugins.indices.contains(tableView.selectedRow) else { return }
            let plugin = parent.plugins[tableView.selectedRow]
            guard plugin.id != parent.selectedPluginID else { return }
            parent.selectedPluginID = plugin.id
            selectedID = plugin.id
            tableView.reloadData(forRowIndexes: tableView.rows(in: tableView.visibleRect).indexSet, columnIndexes: IndexSet(integer: 0))
        }

        private func synchronizeSelection() {
            guard let tableView else { return }
            guard let id = parent.selectedPluginID,
                  let row = parent.plugins.firstIndex(where: { $0.id == id }) else {
                tableView.deselectAll(nil)
                return
            }
            if tableView.selectedRow != row {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }

        private static func signature(
            for plugins: [CodexPluginSummary],
            showsToggle: Bool,
            pendingPluginIDs: Set<String>
        ) -> Int {
            var hasher = Hasher()
            hasher.combine(showsToggle)
            hasher.combine(pendingPluginIDs)
            hasher.combine(plugins.count)
            for plugin in plugins {
                hasher.combine(plugin.id)
                hasher.combine(plugin.installed)
                hasher.combine(plugin.enabled)
                hasher.combine(plugin.displayName)
                hasher.combine(plugin.detail)
                hasher.combine(plugin.icon)
            }
            return hasher.finalize()
        }
    }
}

private extension NSRange {
    var indexSet: IndexSet {
        guard location != NSNotFound, length > 0 else { return [] }
        return IndexSet(integersIn: location..<(location + length))
    }
}

@MainActor
private final class CodexPluginCatalogCell: NSTableCellView {
    private let chrome = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    private let enabledSwitch = NSSwitch()
    private let statusImageView = NSImageView()
    private let trailingControls = NSStackView()
    private var plugin: CodexPluginSummary?
    private var theme: CodexAgentTheme?
    private var selected = false
    private var onAction: ((CodexPluginRouteAction) -> Void)?
    private var representedPluginID: String?
    private var iconTask: Task<Void, Never>?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        translatesAutoresizingMaskIntoConstraints = false
        chrome.translatesAutoresizingMaskIntoConstraints = false
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = 8
        addSubview(chrome)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = .init(pointSize: 18, weight: .medium)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .tertiaryLabelColor
        chrome.addSubview(iconView)

        for label in [titleLabel, detailLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
        }
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.maximumNumberOfLines = 2
        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(labels)

        trailingControls.translatesAutoresizingMaskIntoConstraints = false
        trailingControls.orientation = .horizontal
        trailingControls.alignment = .centerY
        trailingControls.spacing = 8
        chrome.addSubview(trailingControls)

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.target = self
        actionButton.action = #selector(performPrimaryAction)
        actionButton.controlSize = .small
        trailingControls.addArrangedSubview(actionButton)

        enabledSwitch.translatesAutoresizingMaskIntoConstraints = false
        enabledSwitch.target = self
        enabledSwitch.action = #selector(toggleEnabled)
        enabledSwitch.controlSize = .small
        trailingControls.addArrangedSubview(enabledSwitch)

        statusImageView.translatesAutoresizingMaskIntoConstraints = false
        statusImageView.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        statusImageView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Enabled")
        statusImageView.setAccessibilityElement(true)
        statusImageView.setAccessibilityLabel("Enabled")
        trailingControls.addArrangedSubview(statusImageView)

        NSLayoutConstraint.activate([
            chrome.leadingAnchor.constraint(equalTo: leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: trailingAnchor),
            chrome.topAnchor.constraint(equalTo: topAnchor),
            chrome.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: chrome.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),
            labels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            labels.centerYAnchor.constraint(equalTo: chrome.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: trailingControls.leadingAnchor, constant: -8),
            trailingControls.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -8),
            trailingControls.centerYAnchor.constraint(equalTo: chrome.centerYAnchor),
            statusImageView.widthAnchor.constraint(equalToConstant: 28),
            statusImageView.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        plugin: CodexPluginSummary,
        selected: Bool,
        showsToggle: Bool,
        isPending: Bool,
        theme: CodexAgentTheme,
        onAction: @escaping (CodexPluginRouteAction) -> Void
    ) {
        self.plugin = plugin
        representedPluginID = plugin.id
        self.selected = selected
        self.theme = theme
        self.onAction = onAction
        titleLabel.stringValue = plugin.displayName
        detailLabel.stringValue = plugin.detail
        iconView.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
        iconTask?.cancel()
        let prefersDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if let url = plugin.icon.url(prefersDark: prefersDark) {
            if url.isFileURL, let image = CodexPluginImageRepository.cachedOrLocalImage(for: url) {
                iconView.image = image
            } else {
                let pluginID = plugin.id
                iconTask = Task { [weak self] in
                    guard let image = await CodexPluginImageRepository.image(for: url),
                          !Task.isCancelled,
                          self?.representedPluginID == pluginID else { return }
                    self?.iconView.image = image
                }
            }
        }
        let showsEnabledSwitch = showsToggle && plugin.supportsEnabledToggle
        enabledSwitch.isHidden = !showsEnabledSwitch
        enabledSwitch.state = plugin.enabled ? .on : .off
        enabledSwitch.isEnabled = !isPending
        statusImageView.isHidden = !(showsToggle && !showsEnabledSwitch && plugin.installed)
        statusImageView.contentTintColor = effectiveAppearance.codexResolve(theme.colors.textTertiary)
        actionButton.isHidden = showsToggle
        actionButton.isEnabled = !isPending
        actionButton.isBordered = true
        actionButton.bezelStyle = .rounded
        if !showsToggle {
            if !plugin.installed && plugin.installPolicy == "AVAILABLE" {
                actionButton.title = "Add"
                actionButton.image = nil
            } else {
                actionButton.title = ""
                actionButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More actions")
                actionButton.isBordered = false
            }
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(plugin.displayName), \(plugin.detail)")
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    @objc private func toggleEnabled() {
        guard let plugin else { return }
        onAction?(.setPluginEnabled(.init(plugin: plugin), enabled: enabledSwitch.state == .on))
    }

    @objc private func performPrimaryAction() {
        guard let plugin else { return }
        if !plugin.installed && plugin.installPolicy == "AVAILABLE" {
            onAction?(.installPlugin(.init(plugin: plugin)))
            return
        }
        let menu = NSMenu()
        if plugin.supportsEnabledToggle {
            menu.addItem(actionItem(plugin.enabled ? "Disable" : "Enable") { [weak self] in
                self?.onAction?(.setPluginEnabled(.init(plugin: plugin), enabled: !plugin.enabled))
            })
        }
        if plugin.installed && plugin.installPolicy != "INSTALLED_BY_DEFAULT" {
            menu.addItem(actionItem("Remove") { [weak self] in
                self?.onAction?(.uninstallPlugin(.init(plugin: plugin)))
            })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: actionButton.bounds.minX, y: actionButton.bounds.maxY), in: actionButton)
    }

    private func actionItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: action)
        return item
    }

    private func applyColors() {
        guard let theme else { return }
        let appearance = effectiveAppearance
        titleLabel.textColor = appearance.codexResolve(theme.colors.textPrimary)
        detailLabel.textColor = appearance.codexResolve(theme.colors.textSecondary)
        iconView.contentTintColor = appearance.codexResolve(theme.colors.textTertiary)
        chrome.layer?.backgroundColor = appearance.codexResolve(
            selected ? theme.colors.surfaceElevated : Color.clear
        ).cgColor
    }
}

@MainActor
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.handler = action
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func invoke() { handler() }
}
#endif
