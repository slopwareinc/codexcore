import AppKit
import SwiftUI

struct CodexTranscriptCollectionDiagnostics: Sendable, Equatable {
    var snapshotApplyCount = 0
    var insertedItemCount = 0
    var deletedItemCount = 0
    var reconfiguredItemCount = 0
    var broadReloadCount = 0
    var tickerTargetCount = 0
    var render = CodexTranscriptRenderDiagnostics()
}

struct CodexTranscriptListHost: NSViewRepresentable {
    @Environment(\.codexAgentTheme) private var swiftUITheme
    @Environment(\.codexClipboardService) private var clipboardService

    var presentation: CodexThreadUIPresentation
    var sessionStore: CodexThreadUISessionStore?
    var bottomContentInset: CGFloat
    var contentHorizontalOffset: CGFloat
    var productToolRenderer: CodexProductToolRendererV2?
    var onOpenSubagent: (String) -> Void
    var onEditUserMessage: (String) -> Void
    var onForkChat: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> CodexTranscriptCollectionContainerView {
        let container = CodexTranscriptCollectionContainerView()
        context.coordinator.attach(to: container)
        return container
    }

    func updateNSView(_ container: CodexTranscriptCollectionContainerView, context: Context) {
        context.coordinator.update(
            presentation: presentation,
            sessionStore: sessionStore,
            bottomContentInset: bottomContentInset,
            contentHorizontalOffset: contentHorizontalOffset,
            swiftUITheme: swiftUITheme,
            clipboardService: clipboardService,
            productToolRenderer: productToolRenderer,
            onOpenSubagent: onOpenSubagent,
            onEditUserMessage: onEditUserMessage,
            onForkChat: onForkChat
        )
    }

    static func dismantleNSView(
        _ nsView: CodexTranscriptCollectionContainerView,
        coordinator: Coordinator
    ) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegateFlowLayout {
        private let projector = CodexTranscriptRenderProjector()
        private weak var container: CodexTranscriptCollectionContainerView?
        private var dataSource: NSCollectionViewDiffableDataSource<String, CodexTranscriptRenderItemID>?
        private var currentSnapshot: CodexTranscriptRenderSnapshot?
        private var currentPresentation: CodexThreadUIPresentation?
        private var sessionStore: CodexThreadUISessionStore?
        private var appKitTheme: CodexTranscriptAppKitTheme?
        private var swiftUITheme = CodexAgentTheme.officialDark
        private var clipboardService: any CodexClipboardService = CodexNoopClipboardService()
        private var productToolRenderer: CodexProductToolRendererV2?
        private var onOpenSubagent: (String) -> Void = { _ in }
        private var onEditUserMessage: (String) -> Void = { _ in }
        private var onForkChat: (() -> Void)?
        private var contentHorizontalOffset: CGFloat = 0
        private var projectionTask: Task<Void, Never>?
        private var scrollRestorationTask: Task<Void, Never>?
        private var selectedItemIDs: Set<CodexTranscriptRenderItemID> = []
        private var isRestoringScroll = false
        private var lastProjectedWidth: CGFloat = 0
        private var forceReconfigureAll = false
        private var activeTickerItemID: CodexTranscriptRenderItemID?
        private var ticker: Timer?
        private(set) var diagnostics = CodexTranscriptCollectionDiagnostics()

        func attach(to container: CodexTranscriptCollectionContainerView) {
            self.container = container
            let collectionView = container.collectionView
            collectionView.delegate = self
            collectionView.register(
                CodexTranscriptCollectionItem.self,
                forItemWithIdentifier: CodexTranscriptCollectionItem.reuseIdentifier
            )
            dataSource = NSCollectionViewDiffableDataSource<String, CodexTranscriptRenderItemID>(
                collectionView: collectionView
            ) { [weak self] collectionView, indexPath, itemID in
                guard let self,
                      let item = self.currentSnapshot?.itemsByID[itemID],
                      let theme = self.appKitTheme,
                      let collectionItem = collectionView.makeItem(
                        withIdentifier: CodexTranscriptCollectionItem.reuseIdentifier,
                        for: indexPath
                      ) as? CodexTranscriptCollectionItem else { return nil }
                collectionItem.configure(
                    item: item,
                    appKitTheme: theme,
                    swiftUITheme: self.swiftUITheme,
                    contentHorizontalOffset: self.contentHorizontalOffset,
                    productToolRenderer: self.productToolRenderer,
                    performAction: { [weak self] action in self?.perform(action) },
                    copy: { [weak self] text in self?.clipboardService.copy(text) },
                    editUserMessage: { [weak self] text in self?.onEditUserMessage(text) },
                    forkChat: self.onForkChat,
                    selectionChanged: { [weak self] id, selecting in self?.selectionChanged(id: id, selecting: selecting) }
                )
                return collectionItem
            }
            container.onJumpToLatest = { [weak self] in self?.jumpToLatest() }
            container.onWidthChange = { [weak self] width in self?.widthDidChange(width) }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipViewBoundsChanged),
                name: NSView.boundsDidChangeNotification,
                object: container.scrollView.contentView
            )
        }

        func update(
            presentation: CodexThreadUIPresentation,
            sessionStore: CodexThreadUISessionStore?,
            bottomContentInset: CGFloat,
            contentHorizontalOffset: CGFloat,
            swiftUITheme: CodexAgentTheme,
            clipboardService: any CodexClipboardService,
            productToolRenderer: CodexProductToolRendererV2?,
            onOpenSubagent: @escaping (String) -> Void,
            onEditUserMessage: @escaping (String) -> Void,
            onForkChat: (() -> Void)?
        ) {
            guard let container else { return }
            let nextTheme = CodexTranscriptAppKitTheme(swiftUITheme)
            if appKitTheme?.fingerprint != nextTheme.fingerprint
                || self.contentHorizontalOffset != contentHorizontalOffset {
                forceReconfigureAll = true
            }
            self.currentPresentation = presentation
            self.sessionStore = sessionStore
            self.appKitTheme = nextTheme
            self.swiftUITheme = swiftUITheme
            self.clipboardService = clipboardService
            self.productToolRenderer = productToolRenderer
            self.onOpenSubagent = onOpenSubagent
            self.onEditUserMessage = onEditUserMessage
            self.onForkChat = onForkChat
            self.contentHorizontalOffset = contentHorizontalOffset
            container.bottomContentInset = max(0, bottomContentInset)
            container.layoutSubtreeIfNeeded()
            requestProjection(width: max(container.scrollView.contentSize.width, 320))
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            projectionTask?.cancel()
            projectionTask = nil
            scrollRestorationTask?.cancel()
            scrollRestorationTask = nil
            isRestoringScroll = false
            ticker?.invalidate()
            ticker = nil
            activeTickerItemID = nil
        }

        func waitForProjectionForTesting() async {
            await projectionTask?.value
        }

        var renderedItemIDsForTesting: [CodexTranscriptRenderItemID] {
            currentSnapshot?.orderedItemIDs ?? []
        }

        func renderedItemForTesting(_ id: CodexTranscriptRenderItemID) -> CodexTranscriptRenderItem? {
            currentSnapshot?.itemsByID[id]
        }

        func setSelectingForTesting(_ selecting: Bool, id: CodexTranscriptRenderItemID) {
            selectionChanged(id: id, selecting: selecting)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> NSSize {
            guard let itemID = dataSource?.itemIdentifier(for: indexPath),
                  let item = currentSnapshot?.itemsByID[itemID] else {
                return NSSize(width: collectionView.bounds.width, height: 28)
            }
            let viewportWidth = collectionView.enclosingScrollView?.contentSize.width
                ?? collectionView.bounds.width
            let availableWidth = min(collectionView.bounds.width, viewportWidth)
            return NSSize(width: max(1, availableWidth - 32), height: item.measuredHeight)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            insetForSectionAt section: Int
        ) -> NSEdgeInsets {
            NSEdgeInsets(top: section == 0 ? 0 : 14, left: 0, bottom: 14, right: 0)
        }

        private func requestProjection(width: CGFloat) {
            guard let presentation = currentPresentation, let theme = appKitTheme else { return }
            projectionTask?.cancel()
            lastProjectedWidth = width
            projectionTask = Task { [weak self, projector] in
                do {
                    let snapshot = try await projector.project(
                        presentation: presentation,
                        availableWidth: width,
                        theme: theme
                    )
                    guard !Task.isCancelled else { return }
                    self?.apply(snapshot, presentation: presentation)
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }
        }

        private func apply(
            _ projected: CodexTranscriptRenderSnapshot,
            presentation: CodexThreadUIPresentation
        ) {
            guard currentPresentation?.threadID == projected.threadID,
                  let dataSource else { return }
            let previous = currentSnapshot
            let previousIDs = Set(previous?.orderedItemIDs ?? [])
            let nextIDs = Set(projected.orderedItemIDs)
            var changedIDs = projected.changedItemIDs.intersection(previousIDs).intersection(nextIDs)
            if forceReconfigureAll {
                changedIDs = previousIDs.intersection(nextIDs)
                forceReconfigureAll = false
            }
            currentSnapshot = projected

            var diffable = NSDiffableDataSourceSnapshot<String, CodexTranscriptRenderItemID>()
            diffable.appendSections(projected.sectionIDs)
            for sectionID in projected.sectionIDs {
                diffable.appendItems(projected.itemIDsBySection[sectionID] ?? [], toSection: sectionID)
            }
            if !changedIDs.isEmpty { diffable.reloadItems(Array(changedIDs)) }
            diagnostics.snapshotApplyCount += 1
            diagnostics.insertedItemCount += nextIDs.subtracting(previousIDs).count
            diagnostics.deletedItemCount += previousIDs.subtracting(nextIDs).count
            diagnostics.reconfiguredItemCount += changedIDs.count
            diagnostics.render = projected.diagnostics
            let switchedThread = previous?.threadID != projected.threadID
            let shouldFollow = presentation.isPinnedToBottom && selectedItemIDs.isEmpty
            dataSource.apply(diffable, animatingDifferences: false) { [weak self] in
                guard let self, let container = self.container else { return }
                container.collectionView.collectionViewLayout?.invalidateLayout()
                container.layoutSubtreeIfNeeded()
                container.collectionView.layoutSubtreeIfNeeded()
                if switchedThread {
                    self.restoreScroll(presentation)
                } else if shouldFollow {
                    self.scrollToBottom(markPinned: true)
                }
                self.updateJumpButton()
                self.updateTicker(projected)
            }
        }

        private func perform(_ action: CodexTranscriptRenderAction) {
            guard var presentation = currentPresentation else { return }
            switch action {
            case .toggleWork(let turnID):
                let expanded = !presentation.expandedWorkTurnIDs.contains(turnID)
                if expanded { presentation.expandedWorkTurnIDs.insert(turnID) }
                else { presentation.expandedWorkTurnIDs.remove(turnID) }
                sessionStore?.setWorkExpanded(expanded, turnID: turnID, threadID: presentation.threadID)
            case .toggleRow(let rowID):
                let expanded = !presentation.expandedRowIDs.contains(rowID)
                if expanded { presentation.expandedRowIDs.insert(rowID) }
                else { presentation.expandedRowIDs.remove(rowID) }
                sessionStore?.setRowExpanded(expanded, rowID: rowID, threadID: presentation.threadID)
            case .openSubagent(let threadID):
                onOpenSubagent(threadID)
                return
            }
            currentPresentation = presentation
            requestProjection(width: max(container?.scrollView.contentSize.width ?? lastProjectedWidth, 320))
        }

        private func selectionChanged(id: CodexTranscriptRenderItemID, selecting: Bool) {
            if selecting { selectedItemIDs.insert(id) }
            else { selectedItemIDs.remove(id) }
        }

        private func widthDidChange(_ width: CGFloat) {
            guard abs(width - lastProjectedWidth) > 1 else { return }
            requestProjection(width: max(width, 320))
        }

        @objc private func clipViewBoundsChanged() {
            guard !isRestoringScroll, let container, var presentation = currentPresentation else { return }
            let pinned = distanceToBottom() <= 80
            let rawOffset = container.scrollView.contentView.bounds.origin.y
            presentation.rawScrollOffset = rawOffset
            presentation.isPinnedToBottom = pinned
            currentPresentation = presentation
            sessionStore?.updateScrollState(
                threadID: presentation.threadID,
                rawOffset: rawOffset,
                isPinnedToBottom: pinned
            )
            updateJumpButton()
        }

        private func restoreScroll(_ presentation: CodexThreadUIPresentation) {
            guard let container else { return }
            scrollRestorationTask?.cancel()
            isRestoringScroll = true
            setScrollOrigin(for: presentation, in: container)
            scrollRestorationTask = Task { @MainActor [weak self, weak container] in
                await Task.yield()
                guard !Task.isCancelled, let self, let container,
                      self.currentPresentation?.threadID == presentation.threadID else { return }
                container.collectionView.layoutSubtreeIfNeeded()
                self.setScrollOrigin(for: presentation, in: container)
                await Task.yield()
                guard !Task.isCancelled else { return }
                self.isRestoringScroll = false
                self.updateJumpButton()
            }
        }

        private func setScrollOrigin(
            for presentation: CodexThreadUIPresentation,
            in container: CodexTranscriptCollectionContainerView
        ) {
            let targetY = presentation.isPinnedToBottom
                ? bottomOffset()
                : min(max(-container.scrollView.contentInsets.top, presentation.rawScrollOffset), bottomOffset())
            container.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
            container.scrollView.reflectScrolledClipView(container.scrollView.contentView)
        }

        private func jumpToLatest() {
            scrollToBottom(markPinned: true)
        }

        private func scrollToBottom(markPinned: Bool) {
            guard let container, var presentation = currentPresentation else { return }
            scrollRestorationTask?.cancel()
            scrollRestorationTask = nil
            isRestoringScroll = true
            let targetY = bottomOffset()
            container.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
            container.scrollView.reflectScrolledClipView(container.scrollView.contentView)
            isRestoringScroll = false
            if markPinned {
                presentation.rawScrollOffset = targetY
                presentation.isPinnedToBottom = true
                currentPresentation = presentation
                sessionStore?.updateScrollState(
                    threadID: presentation.threadID,
                    rawOffset: targetY,
                    isPinnedToBottom: true
                )
            }
            updateJumpButton()
        }

        private func bottomOffset() -> CGFloat {
            guard let container else { return 0 }
            let contentHeight = container.collectionView.collectionViewLayout?.collectionViewContentSize.height
                ?? container.collectionView.bounds.height
            return max(
                -container.scrollView.contentInsets.top,
                contentHeight - container.scrollView.contentView.bounds.height + container.scrollView.contentInsets.bottom
            )
        }

        private func distanceToBottom() -> CGFloat {
            guard let container else { return 0 }
            return max(0, bottomOffset() - container.scrollView.contentView.bounds.origin.y)
        }

        private func updateJumpButton() {
            guard let container, let presentation = currentPresentation else { return }
            container.jumpButton.isHidden = presentation.isPinnedToBottom || distanceToBottom() <= 80
        }

        private func updateTicker(_ snapshot: CodexTranscriptRenderSnapshot) {
            let nextID = sessionStore == nil ? nil : snapshot.orderedItemIDs.reversed().first { id in
                guard let header = snapshot.itemsByID[id]?.workHeader,
                      case .working(_, let showsDuration) = header.state else { return false }
                return showsDuration
            }
            guard nextID != activeTickerItemID else { return }
            ticker?.invalidate()
            ticker = nil
            activeTickerItemID = nextID
            diagnostics.tickerTargetCount = nextID == nil ? 0 : 1
            guard nextID != nil else { return }
            let timer = Timer(timeInterval: 1, target: self, selector: #selector(tickWorkingHeader), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }

        @objc private func tickWorkingHeader() {
            guard let activeTickerItemID,
                  let indexPath = dataSource?.indexPath(for: activeTickerItemID),
                  let item = container?.collectionView.item(at: indexPath) as? CodexTranscriptCollectionItem else { return }
            item.updateWorkingHeader(at: Date())
        }
    }
}

@MainActor
final class CodexTranscriptCollectionContainerView: NSView {
    let scrollView = NSScrollView()
    let collectionView = NSCollectionView()
    let jumpButton = NSButton()
    var onJumpToLatest: (() -> Void)?
    var onWidthChange: ((CGFloat) -> Void)?
    var bottomContentInset: CGFloat = 0 {
        didSet {
            guard bottomContentInset != oldValue else { return }
            scrollView.contentInsets = NSEdgeInsets(top: 78, left: 0, bottom: bottomContentInset, right: 0)
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        layout.scrollDirection = .vertical
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.clear]

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentInsets = NSEdgeInsets(top: 78, left: 0, bottom: 0, right: 0)
        addSubview(scrollView)

        jumpButton.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: "Jump to latest")
        jumpButton.imagePosition = .imageOnly
        jumpButton.bezelStyle = .circular
        jumpButton.controlSize = .large
        jumpButton.toolTip = "Jump to latest"
        jumpButton.setAccessibilityLabel("Jump to latest")
        jumpButton.target = self
        jumpButton.action = #selector(jump)
        jumpButton.isHidden = true
        addSubview(jumpButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let viewportWidth = scrollView.contentSize.width
        collectionView.frame.size.width = viewportWidth
        jumpButton.frame = NSRect(
            x: bounds.midX - 20,
            y: bottomContentInset + 12,
            width: 40,
            height: 40
        )
        onWidthChange?(viewportWidth)
    }

    @objc private func jump() {
        onJumpToLatest?()
    }
}
