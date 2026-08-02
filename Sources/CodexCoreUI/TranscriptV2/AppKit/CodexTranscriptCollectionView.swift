import AppKit
import CodexCore
import SwiftUI

struct CodexTranscriptCollectionDiagnostics: Sendable, Equatable {
    var eagerLayoutPassCount = 0
    var snapshotApplyCount = 0
    var threadSwitchDataSourceResetCount = 0
    var broadLayoutMetricInvalidationCount = 0
    var insertedItemCount = 0
    var deletedItemCount = 0
    var reconfiguredItemCount = 0
    var targetedReconfigurePassCount = 0
    var broadReloadCount = 0
    var tickerTargetCount = 0
    var lastSnapshotApplyDurationMilliseconds: Double = 0
    var maximumSnapshotApplyDurationMilliseconds: Double = 0
    var render = CodexTranscriptRenderDiagnostics()
}

struct CodexTranscriptListHost: NSViewRepresentable {
    @Environment(\.codexAgentTheme) private var swiftUITheme
    @Environment(\.codexClipboardService) private var clipboardService
    @Environment(\.colorScheme) private var colorScheme

    var presentation: CodexThreadUIPresentation
    var renderUpdate: CodexCanonicalTranscriptRenderUpdate?
    var presentationStore: CodexPresentationStore?
    var bottomContentInset: CGFloat
    var contentHorizontalOffset: CGFloat
    var responseAnnotations: [CodexResponseTextAnnotation]
    var onUpsertResponseAnnotation: (CodexResponseTextAnnotation) -> Void
    var onRemoveResponseAnnotation: (String) -> Void
    var productToolRenderer: CodexProductToolRendererV2?
    var onOpenSubagent: (String) -> Void
    var onOpenThread: (CodexThreadReferenceV2) -> Void = { _ in }
    var onEditUserMessage: (String) -> Void
    var onForkChat: (() -> Void)?
    var onResolveApproval: (CodexServerRequestKey, Bool) -> Void
    var retryRevision: Int
    var onProjectionError: (String?) -> Void

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
            renderUpdate: renderUpdate,
            presentationStore: presentationStore,
            bottomContentInset: bottomContentInset,
            contentHorizontalOffset: contentHorizontalOffset,
            responseAnnotations: responseAnnotations,
            onUpsertResponseAnnotation: onUpsertResponseAnnotation,
            onRemoveResponseAnnotation: onRemoveResponseAnnotation,
            swiftUITheme: swiftUITheme,
            colorScheme: colorScheme,
            clipboardService: clipboardService,
            productToolRenderer: productToolRenderer,
            onOpenSubagent: onOpenSubagent,
            onOpenThread: onOpenThread,
            onEditUserMessage: onEditUserMessage,
            onForkChat: onForkChat,
            onResolveApproval: onResolveApproval,
            retryRevision: retryRevision,
            onProjectionError: onProjectionError
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: CodexTranscriptCollectionContainerView,
        context: Context
    ) -> CGSize? {
        Self.resolvedViewportSize(for: proposal)
    }

    static func resolvedViewportSize(for proposal: ProposedViewSize) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else {
            return nil
        }
        return CGSize(width: width, height: height)
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
        private var presentationStore: CodexPresentationStore?
        private var appKitTheme: CodexTranscriptAppKitTheme?
        private var swiftUITheme = CodexAgentTheme.officialDark
        private var clipboardService: any CodexClipboardService = CodexNoopClipboardService()
        private var productToolRenderer: CodexProductToolRendererV2?
        private var responseAnnotations: [CodexResponseTextAnnotation] = []
        private var onUpsertResponseAnnotation: (CodexResponseTextAnnotation) -> Void = { _ in }
        private var onRemoveResponseAnnotation: (String) -> Void = { _ in }
        private var onOpenSubagent: (String) -> Void = { _ in }
        private var onOpenThread: (CodexThreadReferenceV2) -> Void = { _ in }
        private var onEditUserMessage: (String) -> Void = { _ in }
        private var onForkChat: (() -> Void)?
        private var onResolveApproval: (CodexServerRequestKey, Bool) -> Void = { _, _ in }
        private var onProjectionError: (String?) -> Void = { _ in }
        private var retryRevision = 0
        private var contentHorizontalOffset: CGFloat = 0
        private var projectionTask: Task<Void, Never>?
        private var projectionGeneration: UInt64 = 0
        private var reflowDebounceTask: Task<Void, Never>?
        private var scrollRestorationTask: Task<Void, Never>?
        private var selectedItemIDs: Set<CodexTranscriptRenderItemID> = []
        private var isRestoringScroll = false
        private var lastProjectedWidth: CGFloat = 0
        private var forceReconfigureAll = false
        private var activeTickerItemID: CodexTranscriptRenderItemID?
        private var ticker: Timer?
        private var hostedPreferredHeightByID: [CodexTranscriptRenderItemID: (revision: Int, height: CGFloat)] = [:]
        private var pendingScrollAnchor: (id: CodexTranscriptRenderItemID, offset: CGFloat)?
        private var hasUnseenOutput = false
        private var shortTranscriptTopInset: CGFloat = 0
        private var turnMinimapEntries: [CodexTranscriptTurnMinimapEntry] = []
        private var turnMinimapTargetYByTurnID: [String: CGFloat] = [:]
        private var lastEagerLayoutSize: NSSize?
        private var lastEagerLayoutBottomInset: CGFloat?
        private(set) var diagnostics = CodexTranscriptCollectionDiagnostics()

        private struct CanonicalProjectionIdentity: Equatable {
            var threadID: ThreadID
            var sourceRevision: StateRevision
            var requestRevision: UInt64
            var expandedWorkTurnIDs: Set<String>
            var expandedRowIDs: Set<String>
            var selectedDiffFileIndexByRowID: [String: Int]
            var agentDisplayNameByThreadID: [String: String]
            var pendingApprovals: [CodexApprovalPrompt]
        }

        private var lastRequestedCanonicalIdentity: CanonicalProjectionIdentity?

        func attach(to container: CodexTranscriptCollectionContainerView) {
            self.container = container
            let collectionView = container.collectionView
            collectionView.delegate = self
            collectionView.register(
                CodexTranscriptCollectionItem.self,
                forItemWithIdentifier: CodexTranscriptCollectionItem.reuseIdentifier
            )
            installDataSource(on: collectionView)
            container.onJumpToLatest = { [weak self] in self?.jumpToLatest() }
            container.onWidthChange = { [weak self] width in self?.widthDidChange(width) }
            container.turnMinimap.onSelect = { [weak self] entry in
                self?.jumpToTurn(entry)
            }
            container.turnMinimap.onHover = { [weak container] entry, marker in
                container?.showTurnPreview(entry, beside: marker)
            }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipViewBoundsChanged),
                name: NSView.boundsDidChangeNotification,
                object: container.scrollView.contentView
            )
        }

        private func installDataSource(on collectionView: NSCollectionView) {
            dataSource = NSCollectionViewDiffableDataSource<String, CodexTranscriptRenderItemID>(
                collectionView: collectionView
            ) { [weak self] collectionView, indexPath, itemID in
                guard let self,
                      let item = self.currentSnapshot?.itemsByID[itemID],
                      let collectionItem = collectionView.makeItem(
                        withIdentifier: CodexTranscriptCollectionItem.reuseIdentifier,
                        for: indexPath
                      ) as? CodexTranscriptCollectionItem else { return nil }
                self.configure(collectionItem, with: item)
                return collectionItem
            }
        }

        func update(
            presentation: CodexThreadUIPresentation,
            renderUpdate: CodexCanonicalTranscriptRenderUpdate? = nil,
            presentationStore: CodexPresentationStore?,
            bottomContentInset: CGFloat,
            contentHorizontalOffset: CGFloat,
            responseAnnotations: [CodexResponseTextAnnotation] = [],
            onUpsertResponseAnnotation: @escaping (CodexResponseTextAnnotation) -> Void = { _ in },
            onRemoveResponseAnnotation: @escaping (String) -> Void = { _ in },
            swiftUITheme: CodexAgentTheme,
            colorScheme: ColorScheme,
            clipboardService: any CodexClipboardService,
            productToolRenderer: CodexProductToolRendererV2?,
            onOpenSubagent: @escaping (String) -> Void,
            onOpenThread: @escaping (CodexThreadReferenceV2) -> Void = { _ in },
            onEditUserMessage: @escaping (String) -> Void,
            onForkChat: (() -> Void)?,
            onResolveApproval: @escaping (CodexServerRequestKey, Bool) -> Void = { _, _ in },
            retryRevision: Int = 0,
            onProjectionError: @escaping (String?) -> Void = { _ in }
        ) {
            guard let container else { return }
            var presentation = presentation
            if presentationStore == nil,
               let currentPresentation,
               currentPresentation.threadID == presentation.threadID {
                // The standalone transcript initializer is fed a fresh
                // presentation value on every streamed update. Preserve the
                // coordinator-owned interaction state instead of treating the
                // refresh as a request to collapse the user's open rows.
                presentation.rawScrollOffset = currentPresentation.rawScrollOffset
                presentation.isPinnedToBottom = currentPresentation.isPinnedToBottom
                presentation.expandedWorkTurnIDs = currentPresentation.expandedWorkTurnIDs
                presentation.expandedRowIDs = currentPresentation.expandedRowIDs
                presentation.selectedDiffFileIndexByRowID =
                    currentPresentation.selectedDiffFileIndexByRowID
            }
            let nextTheme = CodexTranscriptAppKitTheme(swiftUITheme, colorScheme: colorScheme)
            let annotationsChanged = self.responseAnnotations != responseAnnotations
            if appKitTheme?.fingerprint != nextTheme.fingerprint
                || self.contentHorizontalOffset != contentHorizontalOffset {
                forceReconfigureAll = true
            }
            self.currentPresentation = presentation
            self.presentationStore = presentationStore
            self.appKitTheme = nextTheme
            self.swiftUITheme = swiftUITheme
            self.clipboardService = clipboardService
            self.productToolRenderer = productToolRenderer
            self.responseAnnotations = responseAnnotations
            self.onUpsertResponseAnnotation = onUpsertResponseAnnotation
            self.onRemoveResponseAnnotation = onRemoveResponseAnnotation
            self.onOpenSubagent = onOpenSubagent
            self.onOpenThread = onOpenThread
            self.onEditUserMessage = onEditUserMessage
            self.onForkChat = onForkChat
            self.onResolveApproval = onResolveApproval
            self.onProjectionError = onProjectionError
            if annotationsChanged {
                reconfigureVisibleResponseAnnotationItems()
            }
            let shouldRetry = retryRevision != self.retryRevision
            self.retryRevision = retryRevision
            self.contentHorizontalOffset = contentHorizontalOffset
            let normalizedBottomInset = max(0, bottomContentInset)
            container.bottomContentInset = normalizedBottomInset
            let layoutSize = container.bounds.size
            if lastEagerLayoutSize != layoutSize
                || lastEagerLayoutBottomInset != normalizedBottomInset {
                lastEagerLayoutSize = layoutSize
                lastEagerLayoutBottomInset = normalizedBottomInset
                diagnostics.eagerLayoutPassCount &+= 1
                container.layoutSubtreeIfNeeded()
            }
            updateShortTranscriptTopInset()
            if shouldRetry { forceReconfigureAll = true }
            let identity = renderUpdate.map {
                CanonicalProjectionIdentity(
                    threadID: $0.threadID,
                    sourceRevision: $0.sourceRevision,
                    requestRevision: $0.requestSourceRevision,
                    expandedWorkTurnIDs: presentation.expandedWorkTurnIDs,
                    expandedRowIDs: presentation.expandedRowIDs,
                    selectedDiffFileIndexByRowID: presentation.selectedDiffFileIndexByRowID,
                    agentDisplayNameByThreadID: presentation.agentDisplayNameByThreadID,
                    pendingApprovals: presentation.pendingApprovals
                )
            }
            let canonicalInputChanged = identity != nil && identity != lastRequestedCanonicalIdentity
            if identity == nil || canonicalInputChanged || forceReconfigureAll {
                lastRequestedCanonicalIdentity = identity
                requestProjection(width: max(container.scrollView.contentSize.width, 320))
            }
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            projectionTask?.cancel()
            projectionTask = nil
            projectionGeneration &+= 1
            reflowDebounceTask?.cancel()
            reflowDebounceTask = nil
            scrollRestorationTask?.cancel()
            scrollRestorationTask = nil
            isRestoringScroll = false
            ticker?.invalidate()
            ticker = nil
            activeTickerItemID = nil
        }

        func waitForProjectionForTesting() async {
            await reflowDebounceTask?.value
            await projectionTask?.value
        }

        var renderedItemIDsForTesting: [CodexTranscriptRenderItemID] {
            currentSnapshot?.orderedItemIDs ?? []
        }

        var shortTranscriptTopInsetForTesting: CGFloat { shortTranscriptTopInset }

        func renderedItemForTesting(_ id: CodexTranscriptRenderItemID) -> CodexTranscriptRenderItem? {
            currentSnapshot?.itemsByID[id]
        }

        func collectionItemForTesting(_ id: CodexTranscriptRenderItemID) -> CodexTranscriptCollectionItem? {
            guard let indexPath = dataSource?.indexPath(for: id) else { return nil }
            return container?.collectionView.item(at: indexPath) as? CodexTranscriptCollectionItem
        }

        func setSelectingForTesting(_ selecting: Bool, id: CodexTranscriptRenderItemID) {
            selectionChanged(id: id, selecting: selecting)
        }

        func jumpToTurnForTesting(_ turnID: String) {
            guard let entry = container?.turnMinimap.entriesForTesting.first(where: {
                $0.turnID == turnID
            }) else { return }
            jumpToTurn(entry)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> NSSize {
            // NSCollectionViewFlowLayout requires item width STRICTLY less than the
            // collection width minus insets; returning an equal width logs
            // "behavior ... not defined" per item and can corrupt layout during resize.
            let fallbackWidth = max(1, collectionView.bounds.width.rounded(.down) - 1)
            guard let itemID = dataSource?.itemIdentifier(for: indexPath),
                  let item = currentSnapshot?.itemsByID[itemID] else {
                return NSSize(width: fallbackWidth, height: 28)
            }
            let viewportWidth = collectionView.enclosingScrollView?.contentSize.width
                ?? collectionView.bounds.width
            let availableWidth = min(collectionView.bounds.width, viewportWidth)
            let metrics = CodexTranscriptColumnMetrics(viewportWidth: availableWidth)
            let width = min(metrics.cellWidth.rounded(.down) - 1, fallbackWidth)
            return NSSize(width: max(1, width), height: item.measuredHeight)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            insetForSectionAt section: Int
        ) -> NSEdgeInsets {
            NSEdgeInsets(
                top: section == 0 ? shortTranscriptTopInset : CodexTranscriptColumnMetrics.turnGap,
                left: 0,
                bottom: 0,
                right: 0
            )
        }

        private func requestProjection(width: CGFloat) {
            guard let presentation = currentPresentation, let theme = appKitTheme else { return }
            projectionTask?.cancel()
            projectionGeneration &+= 1
            let generation = projectionGeneration
            lastProjectedWidth = width
            projectionTask = Task { [weak self, projector] in
                do {
                    let snapshot = try await projector.project(
                        presentation: presentation,
                        availableWidth: width,
                        theme: theme
                    )
                    guard !Task.isCancelled else { return }
                    guard self?.projectionGeneration == generation else { return }
                    self?.onProjectionError(nil)
                    self?.apply(
                        snapshot,
                        presentation: presentation,
                        projectionGeneration: generation
                    )
                } catch is CancellationError {
                    return
                } catch {
                    self?.onProjectionError("Transcript rendering failed: \(error.localizedDescription)")
                    return
                }
            }
        }

        private func configure(
            _ collectionItem: CodexTranscriptCollectionItem,
            with item: CodexTranscriptRenderItem
        ) {
            guard let theme = appKitTheme else { return }
            collectionItem.configure(
                item: item,
                appKitTheme: theme,
                swiftUITheme: swiftUITheme,
                contentHorizontalOffset: contentHorizontalOffset,
                productToolRenderer: productToolRenderer,
                performAction: { [weak self] action in self?.perform(action) },
                copy: { [weak self] text in self?.clipboardService.copy(text) },
                editUserMessage: { [weak self] text in self?.onEditUserMessage(text) },
                forkChat: onForkChat,
                responseAnnotations: responseAnnotations,
                upsertResponseAnnotation: onUpsertResponseAnnotation,
                removeResponseAnnotation: onRemoveResponseAnnotation,
                selectionChanged: { [weak self] id, selecting in self?.selectionChanged(id: id, selecting: selecting) },
                preferredHeightChanged: { [weak self] id, revision, height in
                    self?.preferredHeightChanged(id: id, revision: revision, height: height)
                }
            )
        }

        private func apply(
            _ projected: CodexTranscriptRenderSnapshot,
            presentation: CodexThreadUIPresentation,
            projectionGeneration: UInt64
        ) {
            var projected = projected
            guard self.projectionGeneration == projectionGeneration,
                  currentPresentation?.threadID == projected.threadID,
                  let dataSource,
                  let container else { return }
            for (id, preferred) in hostedPreferredHeightByID
                where projected.itemsByID[id]?.revision == preferred.revision {
                projected.itemsByID[id]?.measuredHeight = preferred.height
            }
            let previous = currentSnapshot
            let previousIDs = Set(previous?.orderedItemIDs ?? [])
            let nextIDs = Set(projected.orderedItemIDs)
            hostedPreferredHeightByID = hostedPreferredHeightByID.filter { nextIDs.contains($0.key) }
            var changedIDs = projected.changedItemIDs.intersection(previousIDs).intersection(nextIDs)
            if let previous {
                let geometryChangedIDs = previousIDs.intersection(nextIDs).filter { id in
                    guard let oldItem = previous.itemsByID[id],
                          let newItem = projected.itemsByID[id] else { return false }
                    return oldItem.measuredHeight != newItem.measuredHeight
                        || oldItem.maxContentWidth != newItem.maxContentWidth
                        || oldItem.intrinsicContentWidth != newItem.intrinsicContentWidth
                        || oldItem.viewportWidth != newItem.viewportWidth
                }
                changedIDs.formUnion(geometryChangedIDs)
            }
            if forceReconfigureAll {
                changedIDs = previousIDs.intersection(nextIDs)
                forceReconfigureAll = false
            }
            currentSnapshot = projected
            diagnostics.insertedItemCount += nextIDs.subtracting(previousIDs).count
            diagnostics.deletedItemCount += previousIDs.subtracting(nextIDs).count
            diagnostics.reconfiguredItemCount += changedIDs.count
            diagnostics.render = projected.diagnostics
            let switchedThread = previous?.threadID != projected.threadID
            if switchedThread { selectedItemIDs.removeAll(keepingCapacity: true) }
            let shouldFollow = presentation.isPinnedToBottom && selectedItemIDs.isEmpty
            if !presentation.isPinnedToBottom, let lastSection = projected.sectionIDs.last {
                let lastIDs = Set(projected.itemIDsBySection[lastSection] ?? [])
                if !lastIDs.intersection(nextIDs.subtracting(previousIDs).union(changedIDs)).isEmpty {
                    hasUnseenOutput = true
                }
            }
            let structureUnchanged = previous?.threadID == projected.threadID
                && previous?.sectionIDs == projected.sectionIDs
                && previous?.itemIDsBySection == projected.itemIDsBySection
            let applyStartedAt = ContinuousClock.now

            if structureUnchanged {
                if !changedIDs.isEmpty {
                    diagnostics.targetedReconfigurePassCount += 1
                    reconfigure(changedIDs)
                }
                finishApply(
                    projected,
                    presentation: presentation,
                    switchedThread: switchedThread,
                    shouldFollow: shouldFollow,
                    projectionGeneration: projectionGeneration,
                    startedAt: applyStartedAt
                )
                return
            }

            var diffable = NSDiffableDataSourceSnapshot<String, CodexTranscriptRenderItemID>()
            diffable.appendSections(projected.sectionIDs)
            for sectionID in projected.sectionIDs {
                diffable.appendItems(projected.itemIDsBySection[sectionID] ?? [], toSection: sectionID)
            }
            if !changedIDs.isEmpty { diffable.reloadItems(Array(changedIDs)) }
            diagnostics.snapshotApplyCount += 1
            let completion: () -> Void = { [weak self] in
                guard let self else { return }
                self.finishApply(
                    projected,
                    presentation: presentation,
                    switchedThread: switchedThread,
                    shouldFollow: shouldFollow,
                    projectionGeneration: projectionGeneration,
                    startedAt: applyStartedAt
                )
            }
            if switchedThread {
                diagnostics.threadSwitchDataSourceResetCount += 1
                installDataSource(on: container.collectionView)
                self.dataSource?.apply(
                    diffable,
                    animatingDifferences: false,
                    completion: completion
                )
            } else {
                dataSource.apply(
                    diffable,
                    animatingDifferences: !presentation.isPinnedToBottom,
                    completion: completion
                )
            }
        }

        private func reconfigure(_ changedIDs: Set<CodexTranscriptRenderItemID>) {
            guard let dataSource, let container else { return }
            let indexPaths = changedIDs.compactMap { dataSource.indexPath(for: $0) }
            for indexPath in indexPaths {
                guard let id = dataSource.itemIdentifier(for: indexPath),
                      let item = currentSnapshot?.itemsByID[id],
                      let collectionItem = container.collectionView.item(at: indexPath) as? CodexTranscriptCollectionItem else { continue }
                configure(collectionItem, with: item)
            }
            guard !indexPaths.isEmpty else { return }
            invalidateLayoutMetrics(at: Set(indexPaths), in: container)
        }

        private func reconfigureVisibleResponseAnnotationItems() {
            guard let snapshot = currentSnapshot,
                  let dataSource,
                  let container
            else { return }
            for id in snapshot.orderedItemIDs {
                guard snapshot.itemsByID[id]?.allowsResponseAnnotation == true,
                      let indexPath = dataSource.indexPath(for: id),
                      let collectionItem = container.collectionView.item(at: indexPath)
                        as? CodexTranscriptCollectionItem,
                      let item = snapshot.itemsByID[id]
                else { continue }
                configure(collectionItem, with: item)
            }
        }

        private func preferredHeightChanged(
            id: CodexTranscriptRenderItemID,
            revision: Int,
            height: CGFloat
        ) {
            guard var item = currentSnapshot?.itemsByID[id],
                  item.revision == revision,
                  abs(item.measuredHeight - height) > 1 else { return }
            hostedPreferredHeightByID[id] = (revision, height)
            item.measuredHeight = height
            currentSnapshot?.itemsByID[id] = item
            guard let indexPath = dataSource?.indexPath(for: id), let container else { return }
            invalidateLayoutMetrics(at: [indexPath], in: container)
            updateShortTranscriptTopInset()
            rebuildTurnMinimap()
            if currentPresentation?.isPinnedToBottom == true, selectedItemIDs.isEmpty {
                scrollToBottom(markPinned: true, contentHeight: projectedContentHeight())
            }
        }

        private func invalidateLayoutMetrics(
            at indexPaths: Set<IndexPath>,
            in container: CodexTranscriptCollectionContainerView
        ) {
            let context = NSCollectionViewFlowLayoutInvalidationContext()
            context.invalidateFlowLayoutAttributes = true
            context.invalidateItems(at: indexPaths)
            container.collectionView.collectionViewLayout?.invalidateLayout(with: context)
        }

        private func finishApply(
            _ projected: CodexTranscriptRenderSnapshot,
            presentation: CodexThreadUIPresentation,
            switchedThread: Bool,
            shouldFollow: Bool,
            projectionGeneration: UInt64,
            startedAt: ContinuousClock.Instant
        ) {
            guard self.projectionGeneration == projectionGeneration,
                  currentSnapshot?.threadID == projected.threadID,
                  let container else { return }
            updateShortTranscriptTopInset()
            let contentHeight = projectedContentHeight(projected)
            let viewportHeight = container.scrollView.contentView.bounds.height
            if contentHeight <= viewportHeight {
                // A short thread (including a single attachment-only turn) must
                // remain docked to the composer. Restoring an old raw offset of
                // zero would otherwise put its only content at the top.
                scrollToBottom(markPinned: true, contentHeight: contentHeight)
            } else if switchedThread {
                restoreScroll(presentation, contentHeight: contentHeight)
            } else if shouldFollow {
                scrollToBottom(markPinned: true, contentHeight: contentHeight)
            } else if let anchor = pendingScrollAnchor,
                      let minY = projectedMinY(for: anchor.id, in: projected) {
                container.scrollView.contentView.setBoundsOrigin(NSPoint(
                    x: 0,
                    y: minY - anchor.offset
                ))
                container.scrollView.reflectScrolledClipView(container.scrollView.contentView)
            }
            pendingScrollAnchor = nil
            updateJumpButton()
            rebuildTurnMinimap()
            updateTicker(projected)
            let elapsed = startedAt.duration(to: .now)
            let milliseconds = Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
            diagnostics.lastSnapshotApplyDurationMilliseconds = milliseconds
            diagnostics.maximumSnapshotApplyDurationMilliseconds = max(
                diagnostics.maximumSnapshotApplyDurationMilliseconds,
                milliseconds
            )
        }

        private func updateShortTranscriptTopInset() {
            guard let container, let snapshot = currentSnapshot else { return }
            let itemHeight = snapshot.orderedItemIDs.reduce(CGFloat.zero) { partial, id in
                partial + (snapshot.itemsByID[id]?.measuredHeight ?? 0)
            }
            let turnGaps = CGFloat(max(0, snapshot.sectionIDs.count - 1))
                * CodexTranscriptColumnMetrics.turnGap
            let visibleHeight = max(
                0,
                container.scrollView.contentView.bounds.height
                    - container.scrollView.contentInsets.top
                    - container.scrollView.contentInsets.bottom
            )
            let desired = max(0, visibleHeight - itemHeight - turnGaps)
            guard abs(desired - shortTranscriptTopInset) > 0.5 else { return }
            shortTranscriptTopInset = desired
            let context = NSCollectionViewFlowLayoutInvalidationContext()
            context.invalidateFlowLayoutDelegateMetrics = true
            context.invalidateFlowLayoutAttributes = true
            diagnostics.broadLayoutMetricInvalidationCount += 1
            container.collectionView.collectionViewLayout?.invalidateLayout(with: context)
        }

        private func projectedContentHeight(
            _ snapshot: CodexTranscriptRenderSnapshot? = nil
        ) -> CGFloat {
            guard let snapshot = snapshot ?? currentSnapshot else { return 0 }
            let itemHeight = snapshot.orderedItemIDs.reduce(CGFloat.zero) { partial, id in
                partial + (snapshot.itemsByID[id]?.measuredHeight ?? 0)
            }
            let turnGaps = CGFloat(max(0, snapshot.sectionIDs.count - 1))
                * CodexTranscriptColumnMetrics.turnGap
            return shortTranscriptTopInset + itemHeight + turnGaps
        }

        private func projectedMinY(
            for targetID: CodexTranscriptRenderItemID,
            in snapshot: CodexTranscriptRenderSnapshot
        ) -> CGFloat? {
            var y = shortTranscriptTopInset
            for (sectionIndex, sectionID) in snapshot.sectionIDs.enumerated() {
                if sectionIndex > 0 { y += CodexTranscriptColumnMetrics.turnGap }
                for id in snapshot.itemIDsBySection[sectionID] ?? [] {
                    if id == targetID { return y }
                    y += snapshot.itemsByID[id]?.measuredHeight ?? 0
                }
            }
            return nil
        }

        private func perform(_ action: CodexTranscriptRenderAction) {
            guard var presentation = currentPresentation else { return }
            switch action {
            case .toggleWork(let turnID):
                captureScrollAnchor()
                let expanded = !presentation.expandedWorkTurnIDs.contains(turnID)
                if expanded { presentation.expandedWorkTurnIDs.insert(turnID) }
                else { presentation.expandedWorkTurnIDs.remove(turnID) }
                presentationStore?.setWorkExpanded(
                    expanded,
                    turnID: turnID,
                    threadID: ThreadID(presentation.threadID)
                )
            case .toggleRow(let rowID):
                captureScrollAnchor()
                let expanded = !presentation.expandedRowIDs.contains(rowID)
                if expanded { presentation.expandedRowIDs.insert(rowID) }
                else { presentation.expandedRowIDs.remove(rowID) }
                presentationStore?.setRowExpanded(
                    expanded,
                    rowID: rowID,
                    threadID: ThreadID(presentation.threadID)
                )
            case .selectDiffFile(let rowID, let index):
                captureScrollAnchor()
                presentation.selectedDiffFileIndexByRowID[rowID] = max(0, index)
                presentationStore?.selectDiffFile(
                    index: index,
                    rowID: rowID,
                    threadID: ThreadID(presentation.threadID)
                )
            case .openSubagent(let threadID):
                onOpenSubagent(threadID)
                return
            case .openThread(let reference):
                onOpenThread(reference)
                return
            case .openURL(let value):
                guard let url = URL(string: value), url.scheme?.lowercased() == "https" else { return }
                NSWorkspace.shared.open(url)
                return
            case .openFile(let path, _):
                let resolved = (path as NSString).expandingTildeInPath
                NSWorkspace.shared.selectFile(resolved, inFileViewerRootedAtPath: "")
                return
            case .resolveApproval(let requestID, let approve):
                onResolveApproval(requestID, approve)
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
            container?.collectionView.collectionViewLayout?.invalidateLayout()
            guard lastProjectedWidth > 0 else {
                requestProjection(width: max(width, 320))
                return
            }
            // Interactive resizes (window drag, pane drag) emit a width per frame;
            // cells stretch at their cached measurements immediately, while the
            // full re-measure/projection waits until the width settles.
            reflowDebounceTask?.cancel()
            reflowDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled, let self else { return }
                let settled = max(self.container?.scrollView.contentSize.width ?? width, 320)
                self.requestProjection(width: settled)
            }
        }

        @objc private func clipViewBoundsChanged() {
            guard !isRestoringScroll, let container, var presentation = currentPresentation else { return }
            let pinned = distanceToBottom() <= 80
            if pinned { hasUnseenOutput = false }
            let rawOffset = container.scrollView.contentView.bounds.origin.y
            presentation.rawScrollOffset = rawOffset
            presentation.isPinnedToBottom = pinned
            currentPresentation = presentation
            presentationStore?.updateScrollState(
                threadID: ThreadID(presentation.threadID),
                rawOffset: rawOffset,
                isPinnedToBottom: pinned
            )
            updateJumpButton()
            updateTurnMinimapVisibleState()
        }

        private func rebuildTurnMinimap() {
            guard let container,
                  let presentation = currentPresentation,
                  let snapshot = currentSnapshot,
                  let theme = appKitTheme else { return }
            let entries = CodexTranscriptTurnMinimapProjection.entries(
                presentation: presentation,
                snapshot: snapshot
            )
            let contentHeight = projectedContentHeight(snapshot)
            let viewportHeight = max(
                0,
                container.scrollView.contentView.bounds.height
                    - container.scrollView.contentInsets.top
                    - container.scrollView.contentInsets.bottom
            )
            guard entries.count >= 3, contentHeight > viewportHeight + 80 else {
                turnMinimapEntries = []
                turnMinimapTargetYByTurnID = [:]
                container.setTurnMinimapVisible(false)
                return
            }

            var targetYByTurnID: [String: CGFloat] = [:]
            for entry in entries {
                let targetY = projectedMinY(for: entry.targetItemID, in: snapshot) ?? 0
                targetYByTurnID[entry.turnID] = targetY
            }
            turnMinimapEntries = entries
            turnMinimapTargetYByTurnID = targetYByTurnID
            container.configureTurnMinimap(
                entries: entries,
                visibleTurnIDs: visibleTurnMinimapTurnIDs(),
                theme: theme
            )
        }

        private func visibleTurnMinimapTurnIDs() -> Set<String> {
            guard let container, let snapshot = currentSnapshot else { return [] }
            return CodexTranscriptTurnVisibilityProjection.visibleTurnIDs(
                entries: turnMinimapEntries,
                targetYByTurnID: turnMinimapTargetYByTurnID,
                contentHeight: projectedContentHeight(snapshot),
                viewport: container.scrollView.documentVisibleRect
            )
        }

        private func updateTurnMinimapVisibleState() {
            container?.setTurnMinimapVisibleTurns(visibleTurnMinimapTurnIDs())
        }

        private func jumpToTurn(_ entry: CodexTranscriptTurnMinimapEntry) {
            guard let container,
                  let snapshot = currentSnapshot,
                  var presentation = currentPresentation,
                  let targetMinY = projectedMinY(for: entry.targetItemID, in: snapshot) else { return }
            let targetY = min(
                max(-container.scrollView.contentInsets.top, targetMinY - 24),
                bottomOffset(contentHeight: projectedContentHeight(snapshot))
            )
            container.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
            container.scrollView.reflectScrolledClipView(container.scrollView.contentView)
            presentation.rawScrollOffset = targetY
            presentation.isPinnedToBottom = distanceToBottom() <= 80
            currentPresentation = presentation
            presentationStore?.updateScrollState(
                threadID: ThreadID(presentation.threadID),
                rawOffset: targetY,
                isPinnedToBottom: presentation.isPinnedToBottom
            )
            container.showTurnPreview(nil, beside: nil)
            updateJumpButton()
            updateTurnMinimapVisibleState()
        }

        private func restoreScroll(
            _ presentation: CodexThreadUIPresentation,
            contentHeight: CGFloat
        ) {
            guard let container else { return }
            scrollRestorationTask?.cancel()
            isRestoringScroll = true
            setScrollOrigin(for: presentation, in: container, contentHeight: contentHeight)
            scrollRestorationTask = Task { @MainActor [weak self, weak container] in
                await Task.yield()
                guard !Task.isCancelled, let self, let container,
                      self.currentPresentation?.threadID == presentation.threadID else { return }
                self.setScrollOrigin(for: presentation, in: container, contentHeight: contentHeight)
                self.isRestoringScroll = false
                self.updateJumpButton()
                self.updateTurnMinimapVisibleState()
            }
        }

        private func setScrollOrigin(
            for presentation: CodexThreadUIPresentation,
            in container: CodexTranscriptCollectionContainerView,
            contentHeight: CGFloat
        ) {
            let targetY = presentation.isPinnedToBottom
                ? bottomOffset(contentHeight: contentHeight)
                : min(
                    max(-container.scrollView.contentInsets.top, presentation.rawScrollOffset),
                    bottomOffset(contentHeight: contentHeight)
                )
            container.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
            container.scrollView.reflectScrolledClipView(container.scrollView.contentView)
        }

        private func jumpToLatest() {
            hasUnseenOutput = false
            scrollToBottom(markPinned: true)
        }

        private func scrollToBottom(markPinned: Bool, contentHeight: CGFloat? = nil) {
            guard let container, var presentation = currentPresentation else { return }
            scrollRestorationTask?.cancel()
            scrollRestorationTask = nil
            isRestoringScroll = true
            let targetY = bottomOffset(contentHeight: contentHeight)
            container.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
            container.scrollView.reflectScrolledClipView(container.scrollView.contentView)
            isRestoringScroll = false
            if markPinned {
                hasUnseenOutput = false
                presentation.rawScrollOffset = targetY
                presentation.isPinnedToBottom = true
                currentPresentation = presentation
                presentationStore?.updateScrollState(
                    threadID: ThreadID(presentation.threadID),
                    rawOffset: targetY,
                    isPinnedToBottom: true
                )
            }
            updateJumpButton()
            updateTurnMinimapVisibleState()
        }

        private func bottomOffset(contentHeight projectedContentHeight: CGFloat? = nil) -> CGFloat {
            guard let container else { return 0 }
            let contentHeight = projectedContentHeight
                ?? container.collectionView.collectionViewLayout?.collectionViewContentSize.height
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
            let imageName = hasUnseenOutput ? "arrow.down.circle.fill" : "arrow.down"
            container.setJumpButtonImage(named: imageName)
            container.jumpButton.contentTintColor = hasUnseenOutput ? appKitTheme?.accent : nil
        }

        private func captureScrollAnchor() {
            guard let container,
                  currentPresentation?.isPinnedToBottom == false,
                  let indexPath = container.collectionView.indexPathsForVisibleItems().min(),
                  let id = dataSource?.itemIdentifier(for: indexPath),
                  let attributes = container.collectionView.layoutAttributesForItem(at: indexPath) else { return }
            pendingScrollAnchor = (
                id: id,
                offset: attributes.frame.minY - container.scrollView.contentView.bounds.origin.y
            )
        }

        private func updateTicker(_ snapshot: CodexTranscriptRenderSnapshot) {
            let nextID = presentationStore == nil ? nil : snapshot.orderedItemIDs.reversed().first { id in
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
final class CodexTranscriptCollectionView: NSCollectionView {
    private(set) var layoutSubtreeSettlementCount = 0

    override func layoutSubtreeIfNeeded() {
        layoutSubtreeSettlementCount += 1
        super.layoutSubtreeIfNeeded()
    }
}

@MainActor
final class CodexTranscriptCollectionContainerView: NSView {
    private static let jumpButtonImages: [String: NSImage] = [
        "arrow.down": NSImage(
            systemSymbolName: "arrow.down",
            accessibilityDescription: "Jump to latest"
        ),
        "arrow.down.circle.fill": NSImage(
            systemSymbolName: "arrow.down.circle.fill",
            accessibilityDescription: "Jump to latest"
        ),
    ].compactMapValues { $0 }

    let scrollView = NSScrollView()
    let collectionView = CodexTranscriptCollectionView()
    let jumpButton = NSButton()
    let turnMinimap = CodexTranscriptTurnMinimapView()
    let turnPreview = CodexTranscriptTurnPreviewView()
    var onJumpToLatest: (() -> Void)?
    var onWidthChange: ((CGFloat) -> Void)?
    private var turnMinimapTheme: CodexTranscriptAppKitTheme?
    private var turnPreviewHideTask: Task<Void, Never>?
    var bottomContentInset: CGFloat = 0 {
        didSet {
            guard bottomContentInset != oldValue else { return }
            scrollView.contentInsets = NSEdgeInsets(
                top: CodexTranscriptColumnMetrics.topContentInset,
                left: 0,
                bottom: bottomContentInset,
                right: 0
            )
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
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentInsets = NSEdgeInsets(
            top: CodexTranscriptColumnMetrics.topContentInset,
            left: 0,
            bottom: 0,
            right: 0
        )
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

        turnMinimap.isHidden = true
        addSubview(turnMinimap)
        addSubview(turnPreview)
        turnPreview.onHoverChanged = { [weak self] isHovered in
            if isHovered {
                self?.turnPreviewHideTask?.cancel()
            } else {
                self?.scheduleTurnPreviewHide()
            }
        }
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
        let minimapBottom = max(bottomContentInset + 26, 72)
        let minimapTop: CGFloat = 72
        let availableMinimapHeight = max(0, bounds.height - minimapBottom - minimapTop)
        let minimapHeight = turnMinimap.preferredHeight(maximum: availableMinimapHeight)
        turnMinimap.frame = NSRect(
            x: 14,
            y: minimapBottom + (availableMinimapHeight - minimapHeight) / 2,
            width: 30,
            height: minimapHeight
        )
        onWidthChange?(viewportWidth)
    }

    @objc private func jump() {
        onJumpToLatest?()
    }

    func setJumpButtonImage(named name: String) {
        guard jumpButton.image !== Self.jumpButtonImages[name] else { return }
        jumpButton.image = Self.jumpButtonImages[name]
    }

    func configureTurnMinimap(
        entries: [CodexTranscriptTurnMinimapEntry],
        visibleTurnIDs: Set<String>,
        theme: CodexTranscriptAppKitTheme
    ) {
        turnMinimapTheme = theme
        turnMinimap.configure(
            entries: entries,
            visibleTurnIDs: visibleTurnIDs,
            theme: theme
        )
        setTurnMinimapVisible(true)
        needsLayout = true
    }

    func setTurnMinimapVisible(_ visible: Bool) {
        turnMinimap.isHidden = !visible
        if !visible {
            turnPreviewHideTask?.cancel()
            turnPreview.isHidden = true
            turnMinimap.clearHoverMount()
        }
    }

    func setTurnMinimapVisibleTurns(_ turnIDs: Set<String>) {
        turnMinimap.setVisibleTurnIDs(turnIDs)
    }

    func showTurnPreview(
        _ entry: CodexTranscriptTurnMinimapEntry?,
        beside marker: NSView?
    ) {
        guard let entry, let marker, let theme = turnMinimapTheme else {
            scheduleTurnPreviewHide()
            return
        }
        turnPreviewHideTask?.cancel()
        turnPreview.configure(entry: entry, theme: theme)
        let width = min(360, max(220, bounds.width - turnMinimap.frame.maxX - 44))
        let height = turnPreview.preferredHeight(for: width)
        let markerCenter = convert(
            NSPoint(x: marker.bounds.midX, y: marker.bounds.midY),
            from: marker
        )
        turnPreview.frame = NSRect(
            x: turnMinimap.frame.maxX + 12,
            y: min(max(12, markerCenter.y - height / 2), bounds.height - height - 12),
            width: width,
            height: height
        )
        turnPreview.isHidden = false
    }

    private func scheduleTurnPreviewHide() {
        turnPreviewHideTask?.cancel()
        turnPreviewHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled, let self, !self.turnPreview.isPointerInside else { return }
            self.turnPreview.isHidden = true
            self.turnMinimap.clearHoverMount()
        }
    }
}
