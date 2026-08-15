import AppKit
import QuickLookUI
import SwiftUI

private final class CodexTranscriptHoverView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?
    private var hoverTrackingArea: NSTrackingArea?
    var usesPointingHand = false {
        didSet {
            guard usesPointingHand != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverTrackingArea == nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: usesPointingHand ? .pointingHand : .arrow)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?() ?? super.menu(for: event)
    }
}

private final class CodexShimmerTextField: NSTextField {
    private let shimmerLayer = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        shimmerLayer.frame = bounds
    }

    func startShimmer() {
        wantsLayer = true
        shimmerLayer.colors = [
            NSColor.white.withAlphaComponent(0.45).cgColor,
            NSColor.white.cgColor,
            NSColor.white.withAlphaComponent(0.45).cgColor
        ]
        shimmerLayer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmerLayer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmerLayer.locations = [-0.5, 0, 0.5]
        shimmerLayer.frame = bounds
        layer?.mask = shimmerLayer
        guard shimmerLayer.animation(forKey: "codex-shimmer") == nil else { return }
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-0.5, 0, 0.5]
        animation.toValue = [0.5, 1, 1.5]
        animation.duration = 1.35
        animation.repeatCount = .infinity
        shimmerLayer.add(animation, forKey: "codex-shimmer")
    }

    func stopShimmer() {
        shimmerLayer.removeAllAnimations()
        layer?.mask = nil
    }

    var isShimmering: Bool {
        shimmerLayer.animation(forKey: "codex-shimmer") != nil
    }
}

private final class CodexShimmerButton: NSButton {
    private let shimmerLayer = CAGradientLayer()

    override func layout() {
        super.layout()
        shimmerLayer.frame = bounds
    }

    func startShimmer() {
        wantsLayer = true
        shimmerLayer.colors = [
            NSColor.white.withAlphaComponent(0.45).cgColor,
            NSColor.white.cgColor,
            NSColor.white.withAlphaComponent(0.45).cgColor,
        ]
        shimmerLayer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmerLayer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmerLayer.locations = [-0.5, 0, 0.5]
        shimmerLayer.frame = bounds
        layer?.mask = shimmerLayer
        guard shimmerLayer.animation(forKey: "codex-shimmer") == nil else { return }
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-0.5, 0, 0.5]
        animation.toValue = [0.5, 1, 1.5]
        animation.duration = 1.35
        animation.repeatCount = .infinity
        shimmerLayer.add(animation, forKey: "codex-shimmer")
    }

    func stopShimmer() {
        shimmerLayer.removeAllAnimations()
        layer?.mask = nil
    }

    var isShimmering: Bool {
        shimmerLayer.animation(forKey: "codex-shimmer") != nil
    }
}

final class CodexSelectableTranscriptTextView: NSTextView {
    var onSelectionStateChange: ((Bool) -> Void)?
    var contextMenuProvider: ((NSEvent) -> NSMenu?)?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        isHorizontallyResizable = false
        isVerticallyResizable = true
        textContainerInset = .zero
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = 0
        isAutomaticLinkDetectionEnabled = true
        allowsUndo = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        guard isSelectable else {
            super.mouseDown(with: event)
            return
        }
        onSelectionStateChange?(true)
        super.mouseDown(with: event)
        onSelectionStateChange?(selectedRange().length > 0)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?(event) ?? super.menu(for: event)
    }

    func bind(
        _ attributedString: NSAttributedString,
        accessibilityLabel: String,
        preserving selection: NSRange? = nil
    ) {
        let selection = selection ?? selectedRange()
        textStorage?.setAttributedString(attributedString)
        if selection.location != NSNotFound,
           NSMaxRange(selection) <= attributedString.length {
            setSelectedRange(selection)
        } else {
            setSelectedRange(NSRange(location: 0, length: 0))
        }
        setAccessibilityLabel(accessibilityLabel)
    }

    func configureLinkAppearance(theme: CodexTranscriptAppKitTheme, automaticDetection: Bool) {
        isAutomaticLinkDetectionEnabled = automaticDetection
        linkTextAttributes = [
            .foregroundColor: theme.accent,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        displaysLinkToolTips = true
    }
}

@MainActor
final class CodexTranscriptCollectionItem: NSCollectionViewItem, NSTextViewDelegate {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("CodexTranscriptCollectionItem")

    private lazy var selectableTextView: CodexSelectableTranscriptTextView = {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        return CodexSelectableTranscriptTextView(frame: .zero, textContainer: textContainer)
    }()
    private lazy var textScrollView = NSScrollView()
    private lazy var actionButton = CodexShimmerButton()
    private lazy var copyButton = NSButton()
    private lazy var codeHeaderView = NSView()
    private lazy var codeLanguageLabel = NSTextField(labelWithString: "")
    private lazy var chipBackground = NSView()
    private lazy var chipIconView = NSImageView()
    private lazy var chipLabel = CodexShimmerTextField(frame: .zero)
    private lazy var chipDurationLabel = NSTextField(labelWithString: "")
    private lazy var chipStatusLabel = NSTextField(labelWithString: "")
    private lazy var chipDisclosureView = NSImageView()
    private lazy var agentChipContainer = NSView()
    private var agentChipHosts: [NSHostingView<AnyView>] = []
    private var configuredAgentChips: [CodexTranscriptAgentChipRender] = []
    private var agentPreviewPopover: NSPopover?
    private var agentPreviewCloseTask: DispatchWorkItem?
    private var pointerIsInsideAgentPreview = false
    private lazy var diffTabContainer = NSView()
    private var diffTabButtons: [NSButton] = []
    private lazy var diffSelectedUnderline = NSView()
    private var glassBackgroundView: NSHostingView<AnyView>?
    private lazy var approvalAllowButton = NSButton(title: "Allow", target: nil, action: nil)
    private lazy var approvalDenyButton = NSButton(title: "Deny", target: nil, action: nil)
    private lazy var footerTimestampLabel = NSTextField(labelWithString: "")
    private lazy var footerCopyItemButton = NSButton()
    private lazy var footerCopyTurnButton = NSButton()
    private lazy var footerContextButton = NSButton()
    private var responseSelectionActionPanel: CodexResponseSelectionActionPanel?
    private var responseSelectionActionEventMonitor: Any?
    private var responseAnnotationMarkerButtons: [CodexResponseAnnotationMarkerButton] = []
    private var responseAnnotationEditorPanel: CodexResponseAnnotationEditorPanel?
    private var responseAnnotationEditorEventMonitor: Any?
    private var responseAnnotationEditorID: String?
    private var responseAnnotationEditorIsCreating = false
    private var pendingResponseAnnotation: CodexResponseTextAnnotation?
    private var responseAnnotations: [CodexResponseTextAnnotation] = []
    private let backgroundView = NSView()
    private var textControlsInstalled = false
    private var actionControlInstalled = false
    private var copyControlInstalled = false
    private var codeHeaderControlsInstalled = false
    private var chipControlsInstalled = false
    private var agentControlsInstalled = false
    private var diffControlsInstalled = false
    private var approvalControlsInstalled = false
    private var footerControlsInstalled = false
    private var footerActionControlsInstalled = false
    private var agentChipHostCreationCount = 0
    private var hostedView: NSView?
    private var item: CodexTranscriptRenderItem?
    private var appKitTheme: CodexTranscriptAppKitTheme?
    private var swiftUITheme = CodexAgentTheme.officialDark
    private var contentHorizontalOffset: CGFloat = 0
    private var canOpenReview = false
    private var performAction: ((CodexTranscriptRenderAction) -> Void)?
    private var copy: ((String) -> Void)?
    private var editUserMessage: ((String) -> Void)?
    private var retryTurn: ((CodexUserMessageV2) -> Void)?
    private var forkChat: (() -> Void)?
    private var fileNavigationService: any CodexTranscriptFileNavigationService =
        CodexNoopTranscriptFileNavigationService()
    private var contextFileReference: CodexResolvedTranscriptFileReference?
    private var upsertResponseAnnotation: ((CodexResponseTextAnnotation) -> Void)?
    private var removeResponseAnnotation: ((String) -> Void)?
    private var selectionChanged: ((CodexTranscriptRenderItemID, Bool) -> Void)?
    private var preferredHeightChanged: ((CodexTranscriptRenderItemID, Int, CGFloat) -> Void)?
    private var lastReportedPreferredHeight: CGFloat?
    private var isHovered = false
    private var copyConfirmationTokens: [ObjectIdentifier: UUID] = [:]

    var selectableTextViewForTesting: NSTextView {
        ensureTextControls()
        return selectableTextView
    }
    var hoverTrackingAreaCountForTesting: Int { view.trackingAreas.count }
    var hasHostedViewForTesting: Bool { hostedView != nil }
    var footerCopyTurnIsVisibleForTesting: Bool {
        footerActionControlsInstalled && !footerCopyTurnButton.isHidden
    }
    var footerTimestampIsVisibleForTesting: Bool { !footerTimestampLabel.isHidden }
    var footerTimestampForTesting: String { footerTimestampLabel.stringValue }
    var footerCopyItemTitleForTesting: String { footerActionControlsInstalled ? footerCopyItemButton.title : "" }
    var footerCopyItemToolTipForTesting: String? { footerActionControlsInstalled ? footerCopyItemButton.toolTip : nil }
    var footerActionControlsInstalledForTesting: Bool { footerActionControlsInstalled }
    var contentFrameForTesting: NSRect { backgroundView.frame }
    var codeHeaderIsVisibleForTesting: Bool { codeHeaderControlsInstalled && !codeHeaderView.isHidden }
    var codeLanguageForTesting: String { codeHeaderControlsInstalled ? codeLanguageLabel.stringValue : "" }
    var copyButtonAccessibilityDescriptionForTesting: String? {
        copyControlInstalled ? copyButton.image?.accessibilityDescription : nil
    }
    var footerCopyTurnAccessibilityDescriptionForTesting: String? {
        footerActionControlsInstalled ? footerCopyTurnButton.image?.accessibilityDescription : nil
    }
    var chipLabelForTesting: String { chipControlsInstalled ? chipLabel.stringValue : "" }
    var workRowLabelFitsForTesting: Bool {
        guard chipControlsInstalled, let cell = chipLabel.cell else { return false }
        return chipLabel.frame.width + 0.5 >= cell.cellSize.width
    }
    var workRowTitleAndDisclosureGapForTesting: CGFloat? {
        guard chipControlsInstalled, chipDisclosureView.image != nil else { return nil }
        return chipDisclosureView.frame.minX - visibleChipLabelMaxX
    }
    var workRowDisclosureVerticalOffsetForTesting: CGFloat? {
        guard chipControlsInstalled, chipDisclosureView.image != nil else { return nil }
        return chipDisclosureView.frame.midY - chipLabel.frame.midY
    }
    var chipIconDescriptionForTesting: String? {
        chipControlsInstalled ? chipIconView.image?.accessibilityDescription : nil
    }
    var chipIsActionableForTesting: Bool {
        actionControlInstalled && !actionButton.isHidden && actionButton.isEnabled
    }
    var approvalButtonsVisibleForTesting: Bool {
        approvalControlsInstalled && !approvalAllowButton.isHidden && !approvalDenyButton.isHidden
    }
    var textViewportHeightForTesting: CGFloat { textControlsInstalled ? textScrollView.contentSize.height : 0 }
    var textDocumentHeightForTesting: CGFloat { textControlsInstalled ? selectableTextView.frame.height : 0 }
    var textViewportWidthForTesting: CGFloat { textControlsInstalled ? textScrollView.contentSize.width : 0 }
    var textDocumentWidthForTesting: CGFloat { textControlsInstalled ? selectableTextView.frame.width : 0 }
    var hasVerticalScrollerForTesting: Bool { textControlsInstalled && textScrollView.hasVerticalScroller }
    var hasHorizontalScrollerForTesting: Bool { textControlsInstalled && textScrollView.hasHorizontalScroller }
    var copyButtonIsVisibleForTesting: Bool { copyControlInstalled && !copyButton.isHidden }
    var addSelectionToChatIsVisibleForTesting: Bool {
        responseSelectionActionPanel?.isVisible == true
    }
    var addSelectionToChatSizeForTesting: NSSize? {
        responseSelectionActionPanel?.frame.size
    }
    var responseSelectionActionFrameForTesting: NSRect? {
        responseSelectionActionPanel?.frame
    }
    var selectedTextFrameForTesting: NSRect? {
        guard let window = view.window,
              let rect = textRect(for: selectableTextView.selectedRange())
        else { return nil }
        return window.convertToScreen(selectableTextView.convert(rect, to: nil))
    }
    var responseAnnotationMarkerCountForTesting: Int { responseAnnotationMarkerButtons.count }
    var responseAnnotationEditorSizeForTesting: NSSize? {
        responseAnnotationEditorPanel?.frame.size
    }
    var responseAnnotationEditorIsCreatingForTesting: Bool {
        responseAnnotationEditorPanel != nil && responseAnnotationEditorIsCreating
    }
    func addSelectionToChatForTesting() { addSelectionToChat() }
    func saveResponseAnnotationCommentForTesting(_ comment: String) {
        guard let id = responseAnnotationEditorID else { return }
        saveResponseAnnotation(id: id, note: comment)
    }
    var agentChipCountForTesting: Int { agentChipHosts.count }
    var agentChipHostCreationCountForTesting: Int { agentChipHostCreationCount }
    var agentChipTitlesForTesting: [String] {
        configuredAgentChips.map { "\($0.label) · \($0.status.transcriptLabel.lowercased())" }
    }
    var agentPillsUseGlassForTesting: Bool { !agentChipHosts.isEmpty }
    var workRowStatusForTesting: String { chipControlsInstalled ? chipStatusLabel.stringValue : "" }
    var workRowBackgroundIsVisibleForTesting: Bool {
        guard chipControlsInstalled else { return false }
        guard let color = chipBackground.layer?.backgroundColor else { return false }
        return NSColor(cgColor: color)?.alphaComponent ?? 0 > 0.01
    }
    var glassPanelIsVisibleForTesting: Bool { glassBackgroundView != nil }
    var diffTabCountForTesting: Int { diffTabButtons.count }
    var workHeaderHasAlignedDisclosureForTesting: Bool {
        guard actionControlInstalled,
              actionButton.image != nil,
              let imageRect = (actionButton.cell as? NSButtonCell)?.imageRect(forBounds: actionButton.bounds)
        else { return false }
        return abs(imageRect.midY - actionButton.bounds.midY) <= 1
    }
    var workHeaderTitleAndDisclosureGapForTesting: CGFloat? {
        guard actionControlInstalled,
              actionButton.image != nil,
              let cell = actionButton.cell as? NSButtonCell
        else { return nil }
        let titleRect = cell.titleRect(forBounds: actionButton.bounds)
        let imageRect = cell.imageRect(forBounds: actionButton.bounds)
        return imageRect.minX - titleRect.maxX
    }
    var workHeaderShimmerIsActiveForTesting: Bool { actionButton.isShimmering }
    var workRowShimmerIsActiveForTesting: Bool { chipLabel.isShimmering }
    var workHeaderWidthForTesting: CGFloat { actionControlInstalled ? actionButton.frame.width : 0 }
    var textUsedHeightForTesting: CGFloat {
        guard textControlsInstalled,
              let layoutManager = selectableTextView.layoutManager,
              let textContainer = selectableTextView.textContainer else { return 0 }
        layoutManager.ensureLayout(for: textContainer)
        return layoutManager.usedRect(for: textContainer).height
    }

    func copyItemForTesting() { copyItem(copyControlInstalled ? copyButton : nil) }
    func copyTurnForTesting() { copyTurn(footerActionControlsInstalled ? footerCopyTurnButton : nil) }
    func invokePrimaryActionForTesting() { invokePrimaryAction() }
    func editUserForTesting() { editUser() }
    func forkChatForTesting() { invokeForkChat() }
    func setHoveredForTesting(_ hovered: Bool) { setHovered(hovered) }
    func allowApprovalForTesting() { allowApproval() }
    func denyApprovalForTesting() { denyApproval() }
    func openAgentChipForTesting(at index: Int) {
        guard configuredAgentChips.indices.contains(index),
              let threadID = configuredAgentChips[index].threadID else { return }
        performAction?(.openSubagent(threadID: threadID))
    }
    func agentPreviewForTesting(at index: Int) -> CodexTranscriptAgentChipRender? {
        configuredAgentChips.indices.contains(index) ? configuredAgentChips[index] : nil
    }
    func selectDiffTabForTesting(at index: Int) {
        guard diffTabButtons.indices.contains(index) else { return }
        selectDiffTab(diffTabButtons[index])
    }
    func openTurnDiffReviewForTesting() {
        guard let turnDiff = item?.turnDiff, canOpenReview else { return }
        performAction?(.openReview(turnDiff.reviewRequest()))
    }
    func openTurnDiffReviewForTesting(filePath: String) {
        guard let turnDiff = item?.turnDiff, canOpenReview else { return }
        performAction?(.openReview(turnDiff.reviewRequest(selectedFilePath: filePath)))
    }
    func toggleTurnDiffForTesting() {
        guard let rowID = item?.turnDiff?.rowID else { return }
        performAction?(.toggleRow(rowID: rowID))
    }
    func retryTurnForTesting() { invokeRetryTurn() }

    override func loadView() {
        let hoverView = CodexTranscriptHoverView()
        hoverView.onHoverChange = { [weak self] hovered in self?.setHovered(hovered) }
        hoverView.contextMenuProvider = { [weak self] in self?.makeContextMenu() }
        view = hoverView
        view.wantsLayer = true
        backgroundView.wantsLayer = true
        view.addSubview(backgroundView)
    }

    private func ensureTextControls() {
        guard !textControlsInstalled else { return }
        textControlsInstalled = true
        selectableTextView.delegate = self
        selectableTextView.onSelectionStateChange = { [weak self] (selecting: Bool) in
            guard let self, let id = self.item?.id else { return }
            self.selectionChanged?(id, selecting)
        }
        selectableTextView.contextMenuProvider = { [weak self] event in
            self?.makeTextContextMenu(for: event)
        }
        textScrollView.documentView = selectableTextView
        textScrollView.drawsBackground = false
        textScrollView.borderType = .noBorder
        textScrollView.hasVerticalScroller = false
        textScrollView.autohidesScrollers = true
        textScrollView.isHidden = true
        view.addSubview(textScrollView)
    }

    private func responseSelectionActionView() -> AnyView {
        AnyView(
            CodexResponseSelectionActionView { [weak self] in
                self?.addSelectionToChat()
            }
            .codexAgentTheme(swiftUITheme)
        )
    }

    private func ensureActionControl() {
        guard !actionControlInstalled else { return }
        actionControlInstalled = true
        actionButton.isBordered = false
        actionButton.bezelStyle = .inline
        actionButton.alignment = .left
        actionButton.lineBreakMode = .byTruncatingMiddle
        actionButton.target = self
        actionButton.action = #selector(invokePrimaryAction)
        actionButton.isHidden = true
        view.addSubview(actionButton)
    }

    private func ensureCopyControl() {
        guard !copyControlInstalled else { return }
        copyControlInstalled = true
        copyButton.isBordered = false
        copyButton.bezelStyle = .inline
        copyButton.image = Self.symbolImage("doc.on.doc", accessibilityDescription: "Copy")
        copyButton.imagePosition = .imageOnly
        copyButton.target = self
        copyButton.action = #selector(copyItem(_:))
        copyButton.toolTip = "Copy"
        copyButton.setAccessibilityLabel("Copy")
        copyButton.isHidden = true
        view.addSubview(copyButton)
    }

    private func ensureCodeHeaderControls() {
        guard !codeHeaderControlsInstalled else { return }
        codeHeaderControlsInstalled = true
        codeHeaderView.wantsLayer = true
        codeHeaderView.isHidden = true
        codeLanguageLabel.isSelectable = false
        codeLanguageLabel.drawsBackground = false
        codeLanguageLabel.isBordered = false
        codeHeaderView.addSubview(codeLanguageLabel)
        view.addSubview(codeHeaderView)
    }

    private func ensureChipControls() {
        guard !chipControlsInstalled else { return }
        chipControlsInstalled = true
        chipBackground.wantsLayer = true
        chipBackground.isHidden = true
        chipBackground.addSubview(chipIconView)
        chipBackground.addSubview(chipLabel)
        chipBackground.addSubview(chipDurationLabel)
        chipBackground.addSubview(chipStatusLabel)
        chipBackground.addSubview(chipDisclosureView)
        view.addSubview(chipBackground)
    }

    private func ensureAgentControls() {
        guard !agentControlsInstalled else { return }
        agentControlsInstalled = true
        agentChipContainer.isHidden = true
        view.addSubview(agentChipContainer)
    }

    private func ensureDiffControls() {
        guard !diffControlsInstalled else { return }
        diffControlsInstalled = true
        diffTabContainer.wantsLayer = true
        diffTabContainer.isHidden = true
        diffSelectedUnderline.wantsLayer = true
        diffTabContainer.addSubview(diffSelectedUnderline)
        view.addSubview(diffTabContainer)
    }

    private func ensureApprovalControls() {
        guard !approvalControlsInstalled else { return }
        approvalControlsInstalled = true
        approvalAllowButton.target = self
        approvalAllowButton.action = #selector(allowApproval)
        approvalAllowButton.bezelStyle = .rounded
        approvalAllowButton.keyEquivalent = "\r"
        approvalAllowButton.isHidden = true
        view.addSubview(approvalAllowButton)
        approvalDenyButton.target = self
        approvalDenyButton.action = #selector(denyApproval)
        approvalDenyButton.bezelStyle = .rounded
        approvalDenyButton.isHidden = true
        view.addSubview(approvalDenyButton)
    }

    private func ensureFooterControls() {
        guard !footerControlsInstalled else { return }
        footerControlsInstalled = true
        footerTimestampLabel.isSelectable = false
        footerTimestampLabel.drawsBackground = false
        footerTimestampLabel.isBordered = false
        footerTimestampLabel.isHidden = true
        view.addSubview(footerTimestampLabel)
    }

    private func ensureFooterActionControls() {
        guard !footerActionControlsInstalled else { return }
        footerActionControlsInstalled = true
        configureFooterButton(
            footerCopyItemButton,
            systemImage: "doc.on.doc",
            toolTip: "Copy answer",
            action: #selector(copyItem(_:))
        )
        configureFooterButton(
            footerCopyTurnButton,
            systemImage: "doc.on.doc.fill",
            toolTip: "Copy turn",
            action: #selector(copyTurn(_:))
        )
        configureFooterButton(
            footerContextButton,
            systemImage: "square.and.pencil",
            toolTip: "Edit prompt",
            action: #selector(editUser)
        )
        footerCopyItemButton.isHidden = true
        footerCopyTurnButton.isHidden = true
        footerContextButton.isHidden = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let id = item?.id { selectionChanged?(id, false) }
        item = nil
        lastReportedPreferredHeight = nil
        hostedView?.removeFromSuperview()
        hostedView = nil
        clearGlassBackground()
        clearDiffTabs()
        closeAgentPreview()
        closeResponseSelectionAction()
        closeResponseAnnotationEditor()
        pendingResponseAnnotation = nil
        clearResponseAnnotationMarkers()
        if textControlsInstalled {
            selectableTextView.string = ""
            selectableTextView.isSelectable = false
            textScrollView.isHidden = true
        }
        if actionControlInstalled {
            actionButton.isHidden = true
            actionButton.image = nil
            actionButton.stopShimmer()
        }
        if copyControlInstalled { copyButton.isHidden = true }
        if codeHeaderControlsInstalled { codeHeaderView.isHidden = true }
        if chipControlsInstalled {
            chipBackground.isHidden = true
            chipBackground.layer?.borderWidth = 0
            chipLabel.stopShimmer()
            chipDurationLabel.stringValue = ""
            chipStatusLabel.stringValue = ""
            chipDisclosureView.image = nil
        }
        clearAgentChips()
        if approvalControlsInstalled {
            approvalAllowButton.isHidden = true
            approvalDenyButton.isHidden = true
        }
        if footerControlsInstalled {
            footerTimestampLabel.isHidden = true
        }
        if footerActionControlsInstalled {
            footerCopyItemButton.isHidden = true
            footerCopyTurnButton.isHidden = true
            footerContextButton.isHidden = true
        }
        backgroundView.isHidden = true
        if copyControlInstalled {
            resetCopyConfirmation(copyButton, imageName: "doc.on.doc", accessibilityDescription: "Copy")
        }
        if footerActionControlsInstalled {
            resetCopyConfirmation(footerCopyItemButton, imageName: "doc.on.doc", accessibilityDescription: "Copy answer")
            resetCopyConfirmation(footerCopyTurnButton, imageName: "doc.on.doc.fill", accessibilityDescription: "Copy turn")
        }
        isHovered = false
        (view as? CodexTranscriptHoverView)?.usesPointingHand = false
    }

    func configure(
        item: CodexTranscriptRenderItem,
        appKitTheme: CodexTranscriptAppKitTheme,
        swiftUITheme: CodexAgentTheme,
        contentHorizontalOffset: CGFloat,
        productToolRenderer: CodexProductToolRendererV2?,
        canOpenReview: Bool = false,
        performAction: @escaping (CodexTranscriptRenderAction) -> Void,
        copy: @escaping (String) -> Void,
        editUserMessage: @escaping (String) -> Void,
        retryTurn: ((CodexUserMessageV2) -> Void)? = nil,
        forkChat: (() -> Void)?,
        fileNavigationService: any CodexTranscriptFileNavigationService =
            CodexNoopTranscriptFileNavigationService(),
        responseAnnotations: [CodexResponseTextAnnotation] = [],
        upsertResponseAnnotation: @escaping (CodexResponseTextAnnotation) -> Void = { _ in },
        removeResponseAnnotation: @escaping (String) -> Void = { _ in },
        selectionChanged: @escaping (CodexTranscriptRenderItemID, Bool) -> Void,
        preferredHeightChanged: @escaping (CodexTranscriptRenderItemID, Int, CGFloat) -> Void = { _, _, _ in }
    ) {
        let preservesIdentity = self.item?.id == item.id
        let selectionToRestore = preservesIdentity && item.allowsTextSelection && textControlsInstalled
            ? selectableTextView.selectedRange()
            : NSRange(location: 0, length: 0)
        if !preservesIdentity { lastReportedPreferredHeight = nil }
        self.item = item
        self.appKitTheme = appKitTheme
        self.swiftUITheme = swiftUITheme
        self.contentHorizontalOffset = contentHorizontalOffset
        self.canOpenReview = canOpenReview
        self.performAction = performAction
        self.copy = copy
        self.editUserMessage = editUserMessage
        self.retryTurn = retryTurn
        self.forkChat = forkChat
        self.fileNavigationService = fileNavigationService
        contextFileReference = nil
        self.responseAnnotations = responseAnnotations
        self.upsertResponseAnnotation = upsertResponseAnnotation
        self.removeResponseAnnotation = removeResponseAnnotation
        self.selectionChanged = selectionChanged
        self.preferredHeightChanged = preferredHeightChanged
        hostedView?.removeFromSuperview()
        hostedView = nil
        clearGlassBackground()
        clearDiffTabs()
        closeAgentPreview()
        closeResponseSelectionAction()
        closeResponseAnnotationEditor()
        pendingResponseAnnotation = nil
        clearResponseAnnotationMarkers()
        backgroundView.isHidden = true
        if textControlsInstalled { textScrollView.isHidden = true }
        if actionControlInstalled {
            actionButton.isHidden = true
            actionButton.image = nil
            actionButton.stopShimmer()
        }
        if copyControlInstalled { copyButton.isHidden = true }
        if codeHeaderControlsInstalled { codeHeaderView.isHidden = true }
        if chipControlsInstalled {
            chipBackground.isHidden = true
            chipBackground.layer?.borderWidth = 0
            chipLabel.stopShimmer()
            chipDurationLabel.stringValue = ""
            chipStatusLabel.stringValue = ""
            chipDisclosureView.image = nil
        }
        let canReuseAgentChips = preservesIdentity
            && !item.agentChips.isEmpty
            && configuredAgentChips.map(\.id) == item.agentChips.map(\.id)
        if !canReuseAgentChips { clearAgentChips() }
        if approvalControlsInstalled {
            approvalAllowButton.isHidden = true
            approvalDenyButton.isHidden = true
        }
        (view as? CodexTranscriptHoverView)?.usesPointingHand = false
        if footerControlsInstalled {
            footerTimestampLabel.isHidden = true
        }
        if footerActionControlsInstalled {
            footerCopyItemButton.isHidden = true
            footerCopyTurnButton.isHidden = true
            footerContextButton.isHidden = true
        }
        if textControlsInstalled,
           !item.allowsTextSelection,
           selectableTextView.selectedRange().length > 0 {
            selectionChanged(item.id, false)
        }
        if textControlsInstalled { selectableTextView.isSelectable = item.allowsTextSelection }

        if let footer = item.footer {
            ensureFooterControls()
            configureFooter(footer, item: item, theme: appKitTheme)
        } else if let approval = item.approval {
            ensureChipControls()
            ensureApprovalControls()
            configureApproval(approval, item: item, theme: appKitTheme)
        } else if let directive = item.directive {
            ensureChipControls()
            if item.action != nil { ensureActionControl() }
            if case .codeComment = directive.kind, item.preparedText != nil { ensureTextControls() }
            configureDirective(directive, item: item, theme: appKitTheme, preserving: selectionToRestore)
        } else if let turnDiff = item.turnDiff {
            let hosting = NSHostingView(rootView: AnyView(
                CodexTranscriptTurnDiffCard(
                    render: turnDiff,
                    onReview: canOpenReview
                        ? { [weak self] request in self?.performAction?(.openReview(request)) }
                        : nil,
                    onToggleExpanded: { [weak self] in
                        self?.performAction?(.toggleRow(rowID: turnDiff.rowID))
                    }
                )
                .padding(.top, CodexTranscriptTurnDiffCard.topSpacing)
                .codexAgentTheme(swiftUITheme)
            ))
            hosting.setAccessibilityLabel(item.accessibilityLabel)
            hostedView = hosting
            view.addSubview(hosting)
        } else if let diffPanel = item.diffPanel {
            ensureTextControls()
            ensureCopyControl()
            ensureDiffControls()
            configureDiffPanel(
                diffPanel,
                item: item,
                theme: appKitTheme,
                swiftUITheme: swiftUITheme,
                preserving: selectionToRestore
            )
        } else if let code = item.code {
            ensureTextControls()
            ensureCodeHeaderControls()
            ensureCopyControl()
            textScrollView.isHidden = false
            textScrollView.hasHorizontalScroller = true
            selectableTextView.isHorizontallyResizable = true
            selectableTextView.textContainer?.widthTracksTextView = false
            let codeText = item.preparedText?.attributedString ?? NSAttributedString(
                string: code.code,
                attributes: [
                    .font: appKitTheme.codeFont,
                    .foregroundColor: appKitTheme.codeText,
                    .paragraphStyle: Self.paragraphStyle(appKitTheme)
                ]
            )
            selectableTextView.configureLinkAppearance(theme: appKitTheme, automaticDetection: false)
            selectableTextView.bind(
                codeText,
                accessibilityLabel: item.accessibilityLabel,
                preserving: selectionToRestore
            )
            backgroundView.isHidden = false
            codeHeaderView.isHidden = false
            codeLanguageLabel.stringValue = code.language?.isEmpty == false ? code.language! : "code"
            codeLanguageLabel.font = appKitTheme.captionFont
            codeLanguageLabel.textColor = appKitTheme.codeFaint
            copyButton.isHidden = false
            if item.isScrollableOutput {
                backgroundView.isHidden = true
                installGlassBackground(theme: swiftUITheme)
            }
        } else if let preparedText = item.preparedText {
            ensureTextControls()
            textScrollView.isHidden = false
            let isExpandedOutput = item.textRole == .expandedOutput
            textScrollView.hasHorizontalScroller = isExpandedOutput
            selectableTextView.isHorizontallyResizable = isExpandedOutput
            selectableTextView.textContainer?.widthTracksTextView = !isExpandedOutput
            selectableTextView.configureLinkAppearance(
                theme: appKitTheme,
                automaticDetection: isExpandedOutput
            )
            selectableTextView.bind(
                preparedText.attributedString,
                accessibilityLabel: item.accessibilityLabel,
                preserving: selectionToRestore
            )
            if item.textRole == .user || item.textRole == .expandedOutput {
                backgroundView.isHidden = false
            }
            if item.isScrollableOutput {
                backgroundView.isHidden = true
                installGlassBackground(theme: swiftUITheme)
            }
        } else if !item.agentChips.isEmpty {
            ensureAgentControls()
            configureAgentChips(item.agentChips, theme: appKitTheme, swiftUITheme: swiftUITheme)
        } else if let header = item.workHeader {
            ensureActionControl()
            actionButton.isHidden = false
            actionButton.font = appKitTheme.captionFont
            actionButton.contentTintColor = appKitTheme.textTertiary
            actionButton.title = Self.workHeaderTitle(header, at: Date())
            actionButton.image = Self.workHeaderDisclosureImage(header)
            actionButton.imagePosition = .imageTrailing
            actionButton.imageScaling = .scaleProportionallyDown
            actionButton.imageHugsTitle = true
            actionButton.isEnabled = item.action != nil
            actionButton.setAccessibilityLabel(item.accessibilityLabel)
            if case .working = header.state { actionButton.startShimmer() }
        } else if let row = item.workRow {
            let isActionable = item.action != nil
            ensureChipControls()
            chipBackground.isHidden = false
            chipBackground.layer?.cornerRadius = 0
            chipBackground.layer?.backgroundColor = NSColor.clear.cgColor
            chipBackground.layer?.borderWidth = 0
            chipIconView.image = Self.symbolImage(
                Self.chipIconName(row),
                accessibilityDescription: Self.chipIconAccessibilityDescription(row)
            )
            chipIconView.contentTintColor = row.style.isSemanticActivity
                ? appKitTheme.textTertiary
                : Self.statusColor(row.status, theme: appKitTheme)
            chipLabel.stringValue = row.label
            chipLabel.font = appKitTheme.captionFont
            chipLabel.textColor = appKitTheme.textTertiary
            if row.status == .inProgress { chipLabel.startShimmer() }
            chipDurationLabel.stringValue = row.durationMs.map(CodexWorkBlockViewV2.duration) ?? ""
            chipDurationLabel.font = appKitTheme.microFont
            chipDurationLabel.textColor = appKitTheme.textTertiary
            chipStatusLabel.stringValue = row.style.isSemanticActivity
                ? ""
                : Self.workStatusTitle(row)
            chipStatusLabel.font = appKitTheme.captionFont
            chipStatusLabel.textColor = Self.statusColor(row.status, theme: appKitTheme)
            chipDisclosureView.image = Self.chipDisclosureImage(row, isActionable: isActionable)
            chipDisclosureView.contentTintColor = appKitTheme.textTertiary
            if row.isExpanded && item.copyPayload != nil {
                ensureCopyControl()
                copyButton.isHidden = false
                copyButton.toolTip = "Copy output"
                copyButton.setAccessibilityLabel("Copy output")
            }
            if isActionable {
                ensureActionControl()
                actionButton.isHidden = false
                actionButton.isEnabled = true
                actionButton.title = ""
                actionButton.setAccessibilityLabel(item.accessibilityLabel)
            }
            (view as? CodexTranscriptHoverView)?.usesPointingHand = isActionable
        } else if let productTool = item.productTool {
            if let rendered = productToolRenderer?.render(productTool) {
                let hosting = NSHostingView(rootView: AnyView(rendered.codexAgentTheme(swiftUITheme)))
                hosting.setAccessibilityLabel(item.accessibilityLabel)
                hostedView = hosting
                view.addSubview(hosting)
            } else {
                ensureActionControl()
                actionButton.isHidden = false
                actionButton.isEnabled = item.action != nil
                actionButton.font = appKitTheme.captionFont
                actionButton.contentTintColor = appKitTheme.textTertiary
                actionButton.title = CodexProductToolPresentationV2.label(productTool)
                actionButton.image = Self.symbolImage(
                    CodexProductToolPresentationV2.systemImage(productTool),
                    accessibilityDescription: item.accessibilityLabel
                )
                actionButton.imagePosition = .imageLeading
                actionButton.imageScaling = .scaleProportionallyDown
                actionButton.imageHugsTitle = true
                if productTool.status == .inProgress { actionButton.startShimmer() }
                actionButton.setAccessibilityLabel(item.accessibilityLabel)
                (view as? CodexTranscriptHoverView)?.usesPointingHand = item.action != nil
            }
        }

        updateFooterChromeVisibility()
        updateResponseAnnotationChrome()
        view.needsLayout = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let item, let theme = appKitTheme else { return }
        let liveViewportWidth = liveTranscriptViewportWidth(fallback: item.viewportWidth)
        let metrics = CodexTranscriptColumnMetrics(viewportWidth: liveViewportWidth)
        let outerWidth = metrics.outerWidth(theme)
        let centerX = liveViewportWidth / 2 + contentHorizontalOffset
        let outerMinX = centerX - outerWidth / 2
        let liveMaximumContentWidth = metrics.contentWidth(for: item.contentWidthPolicy, theme: theme)
        let contentWidth = min(
            item.intrinsicContentWidth ?? liveMaximumContentWidth,
            liveMaximumContentWidth,
            outerWidth - item.indentation
        )
        let contentX = item.isTrailingAligned
            ? outerMinX + outerWidth - contentWidth
            : outerMinX + item.indentation
        let contentFrame = NSRect(
            x: contentX,
            y: item.bottomSpacing,
            width: contentWidth,
            height: max(0, view.bounds.height - item.bottomSpacing)
        )

        backgroundView.frame = contentFrame
        backgroundView.layer?.cornerRadius = item.textRole == .user ? theme.bubbleRadius : theme.cardRadius
        backgroundView.layer?.backgroundColor = Self.backgroundColor(item: item, theme: theme).cgColor
        backgroundView.layer?.borderColor = Self.borderColor(item: item, theme: theme).cgColor
        backgroundView.layer?.borderWidth = backgroundView.isHidden ? 0 : 1
        glassBackgroundView?.frame = contentFrame

        if item.footer != nil {
            layoutFooter(in: contentFrame, trailing: item.isTrailingAligned)
        } else if item.approval != nil {
            layoutApproval(in: contentFrame)
        } else if let directive = item.directive {
            layoutDirective(directive, item: item, in: contentFrame)
        } else if let diffPanel = item.diffPanel {
            layoutDiffPanel(diffPanel, in: contentFrame)
        } else if item.code != nil {
            let headerHeight: CGFloat = 32
            codeHeaderView.frame = NSRect(
                x: contentX,
                y: contentFrame.maxY - headerHeight,
                width: contentWidth,
                height: headerHeight
            )
            codeHeaderView.layer?.backgroundColor = theme.codeHeader.cgColor
            codeHeaderView.layer?.cornerRadius = theme.cardRadius
            codeHeaderView.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            codeLanguageLabel.frame = NSRect(x: 12, y: 5, width: max(40, contentWidth - 58), height: 22)
            copyButton.frame = NSRect(x: contentFrame.maxX - 36, y: contentFrame.maxY - 29, width: 28, height: 26)
            layoutSelectableText(
                in: NSRect(x: contentX + 12, y: 10, width: contentWidth - 24, height: max(20, view.bounds.height - 52)),
                allowsHorizontalScrolling: true,
                allowsVerticalScrolling: item.isScrollableOutput
            )
        } else if item.preparedText != nil {
            let insetX: CGFloat = item.textRole == .user
                ? CodexTranscriptColumnMetrics.userBubbleHorizontalPadding
                : (item.textRole == .expandedOutput ? 12 : 0)
            let insetY: CGFloat = item.textRole == .user
                ? CodexTranscriptColumnMetrics.userBubbleVerticalPadding
                : (item.textRole == .expandedOutput ? 8 : CodexTranscriptColumnMetrics.itemGap / 2)
            let textFrame = contentFrame.insetBy(dx: insetX, dy: insetY)
            layoutSelectableText(
                in: textFrame,
                allowsHorizontalScrolling: item.textRole == .expandedOutput,
                allowsVerticalScrolling: item.isScrollableOutput
            )
        } else if !item.agentChips.isEmpty {
            layoutAgentChips(item.agentChips, in: contentFrame, theme: theme)
        } else if item.workHeader != nil {
            let titleWidth = ceil((actionButton.title as NSString).size(
                withAttributes: [.font: actionButton.font ?? theme.captionFont]
            ).width)
            actionButton.frame = NSRect(
                x: contentFrame.minX,
                y: contentFrame.minY,
                width: min(contentFrame.width, titleWidth + (actionButton.image == nil ? 8 : 24)),
                height: contentFrame.height
            )
        } else if item.workRow != nil {
            let isActionable = item.action != nil
            chipBackground.frame = contentFrame
            let rowMidY = contentFrame.height / 2
            let disclosureWidth: CGFloat = isActionable ? 14 : 0
            let iconSize: CGFloat = 15
            let iconX: CGFloat = 0
            chipIconView.frame = NSRect(x: iconX, y: rowMidY - iconSize / 2, width: iconSize, height: iconSize)

            chipStatusLabel.sizeToFit()
            chipDurationLabel.sizeToFit()
            let statusWidth = chipStatusLabel.frame.width
            chipDurationLabel.sizeToFit()
            let durationWidth = chipDurationLabel.stringValue.isEmpty ? 0 : chipDurationLabel.frame.width
            let copyReserve: CGFloat = copyControlInstalled && !copyButton.isHidden ? 34 : 0
            let labelX = iconX + iconSize + 8
            let disclosureReserve = isActionable ? disclosureWidth + 8 : 0
            let trailingWidth = statusWidth
                + (durationWidth > 0 ? durationWidth + 10 : 0)
                + copyReserve
                + disclosureReserve
            let naturalLabelWidth = ceil(chipLabel.cell?.cellSize.width ?? 20)
            let labelWidth = min(
                naturalLabelWidth,
                max(20, contentFrame.width - labelX - trailingWidth - 20)
            )
            chipLabel.frame = NSRect(x: labelX, y: rowMidY - 10, width: labelWidth, height: 20)
            let disclosureX = min(
                visibleChipLabelMaxX + 6,
                chipLabel.frame.maxX + 6
            )
            chipDisclosureView.frame = NSRect(
                x: disclosureX,
                y: rowMidY - disclosureWidth / 2,
                width: disclosureWidth,
                height: disclosureWidth
            )
            let labelTrailingX = isActionable
                ? chipDisclosureView.frame.maxX
                : visibleChipLabelMaxX
            chipDurationLabel.frame = NSRect(
                x: labelTrailingX + (durationWidth > 0 ? 10 : 0),
                y: rowMidY - 9,
                width: durationWidth,
                height: 18
            )
            chipStatusLabel.frame = NSRect(
                x: (durationWidth > 0 ? chipDurationLabel.frame.maxX : labelTrailingX) + 10,
                y: rowMidY - 10,
                width: statusWidth,
                height: 20
            )
            if copyControlInstalled, !copyButton.isHidden {
                copyButton.frame = NSRect(
                    x: contentFrame.maxX - 28,
                    y: contentFrame.midY - 12,
                    width: 26,
                    height: 24
                )
            }
            if actionControlInstalled {
                actionButton.frame = NSRect(
                    x: contentFrame.minX,
                    y: contentFrame.minY,
                    width: max(0, contentFrame.width - copyReserve),
                    height: contentFrame.height
                )
            }
        } else if actionControlInstalled {
            actionButton.frame = contentFrame
        }
        if let hostedView {
            hostedView.frame = contentFrame
            hostedView.layoutSubtreeIfNeeded()
            let preferredHeight = max(44, ceil(hostedView.fittingSize.height))
            if abs(preferredHeight - item.measuredHeight) > 1,
               lastReportedPreferredHeight != preferredHeight {
                lastReportedPreferredHeight = preferredHeight
                let id = item.id
                let revision = item.revision
                Task { @MainActor [weak self] in
                    self?.preferredHeightChanged?(id, revision, preferredHeight)
                }
            }
        }
        layoutResponseAnnotationChrome()
    }

    private func liveTranscriptViewportWidth(fallback: CGFloat) -> CGFloat {
        var ancestor: NSView? = view
        while let current = ancestor {
            if let scrollView = current.enclosingScrollView {
                return scrollView.contentSize.width
            }
            ancestor = current.superview
        }
        return fallback
    }

    private func configureFooterButton(
        _ button: NSButton,
        systemImage: String,
        toolTip: String,
        action: Selector
    ) {
        button.isBordered = false
        button.bezelStyle = .inline
        button.focusRingType = .none
        button.title = ""
        button.image = Self.symbolImage(systemImage, accessibilityDescription: toolTip)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.toolTip = toolTip
        button.setAccessibilityLabel(toolTip)
        view.addSubview(button)
    }

    private func configureApproval(
        _ approval: CodexTranscriptApprovalRender,
        item: CodexTranscriptRenderItem,
        theme: CodexTranscriptAppKitTheme
    ) {
        chipBackground.isHidden = false
        chipBackground.layer?.cornerRadius = CodexTranscriptColumnMetrics.actionCardRadius
        chipBackground.layer?.backgroundColor = theme.warning.withAlphaComponent(0.10).cgColor
        chipBackground.layer?.borderColor = theme.warning.withAlphaComponent(0.35).cgColor
        chipBackground.layer?.borderWidth = 1
        chipIconView.image = Self.symbolImage("hand.raised", accessibilityDescription: "Approval needed")
        chipIconView.contentTintColor = theme.warning
        chipLabel.stringValue = "Approval needed — \(approval.summary)"
        chipLabel.font = theme.captionFont
        chipLabel.textColor = theme.textPrimary
        approvalAllowButton.isHidden = false
        approvalDenyButton.isHidden = false
        approvalAllowButton.font = theme.captionFont
        approvalDenyButton.font = theme.captionFont
        approvalAllowButton.setAccessibilityLabel("Allow \(approval.summary)")
        approvalDenyButton.setAccessibilityLabel("Deny \(approval.summary)")
    }

    private func layoutApproval(in contentFrame: NSRect) {
        chipBackground.frame = contentFrame
        chipIconView.frame = NSRect(x: 10, y: contentFrame.height - 28, width: 16, height: 16)
        chipLabel.frame = NSRect(x: 34, y: contentFrame.height - 31, width: max(80, contentFrame.width - 44), height: 22)
        approvalDenyButton.frame = NSRect(x: contentFrame.maxX - 156, y: 8, width: 68, height: 26)
        approvalAllowButton.frame = NSRect(x: contentFrame.maxX - 80, y: 8, width: 70, height: 26)
    }

    private func configureDirective(
        _ directive: CodexTranscriptDirectiveRender,
        item: CodexTranscriptRenderItem,
        theme: CodexTranscriptAppKitTheme,
        preserving selection: NSRange
    ) {
        chipBackground.isHidden = false
        chipBackground.layer?.cornerRadius = CodexTranscriptColumnMetrics.actionCardRadius
        chipBackground.layer?.backgroundColor = theme.surfaceSunken.withAlphaComponent(0.65).cgColor
        chipIconView.image = Self.symbolImage(
            Self.directiveIconName(directive.kind),
            accessibilityDescription: item.accessibilityLabel
        )
        chipIconView.contentTintColor = Self.directiveTint(directive.kind, theme: theme)
        chipLabel.stringValue = Self.directiveLabel(directive.kind)
        chipLabel.font = theme.captionFont
        chipLabel.textColor = theme.textSecondary
        chipDurationLabel.font = theme.microFont
        chipDurationLabel.textColor = theme.textTertiary
        chipDisclosureView.contentTintColor = theme.textTertiary
        chipDisclosureView.image = item.action == nil ? nil : Self.symbolImage(
            "arrow.up.right", accessibilityDescription: "Open"
        )
        if actionControlInstalled {
            actionButton.isHidden = item.action == nil
            actionButton.isEnabled = item.action != nil
            actionButton.title = ""
            actionButton.setAccessibilityLabel(item.accessibilityLabel)
            actionButton.toolTip = Self.directiveToolTip(directive.kind, raw: directive.raw)
        }
        (view as? CodexTranscriptHoverView)?.usesPointingHand = item.action != nil

        if case .codeComment(_, _, let file, let start, _, let priority) = directive.kind {
            chipDurationLabel.stringValue = priority.map { "P\($0)" } ?? ""
            chipDisclosureView.image = Self.symbolImage("doc.on.doc", accessibilityDescription: "Open file")
            if let prepared = item.preparedText?.attributedString {
                textScrollView.isHidden = false
                textScrollView.hasHorizontalScroller = false
                selectableTextView.isHorizontallyResizable = false
                selectableTextView.textContainer?.widthTracksTextView = true
                selectableTextView.configureLinkAppearance(theme: theme, automaticDetection: false)
                selectableTextView.bind(prepared, accessibilityLabel: item.accessibilityLabel, preserving: selection)
            }
            if actionControlInstalled {
                actionButton.toolTip = file + (start.map { ":\($0)" } ?? "")
            }
        }
    }

    private func layoutDirective(
        _ directive: CodexTranscriptDirectiveRender,
        item: CodexTranscriptRenderItem,
        in contentFrame: NSRect
    ) {
        chipBackground.frame = contentFrame
        chipIconView.frame = NSRect(x: 8, y: contentFrame.midY - 8, width: 16, height: 16)
        chipDurationLabel.sizeToFit()
        let badgeWidth = chipDurationLabel.stringValue.isEmpty ? 0 : chipDurationLabel.frame.width + 10
        let disclosureWidth: CGFloat = item.action == nil ? 0 : 16
        chipDisclosureView.frame = NSRect(
            x: contentFrame.width - 10 - disclosureWidth, y: contentFrame.midY - 8,
            width: disclosureWidth, height: 16
        )
        chipDurationLabel.frame = NSRect(
            x: chipDisclosureView.frame.minX - badgeWidth - 6, y: contentFrame.midY - 9,
            width: badgeWidth, height: 18
        )
        chipLabel.frame = NSRect(
            x: 32, y: contentFrame.midY - 10,
            width: max(20, chipDurationLabel.frame.minX - 40), height: 20
        )
        if actionControlInstalled { actionButton.frame = contentFrame }

        if case .codeComment(_, _, let file, let start, _, _) = directive.kind {
            chipIconView.frame.origin.y = contentFrame.height - 26
            chipLabel.frame = NSRect(x: 32, y: contentFrame.height - 28, width: max(20, contentFrame.width - 100), height: 20)
            chipDurationLabel.frame = NSRect(x: contentFrame.width - badgeWidth - 10, y: contentFrame.height - 28, width: badgeWidth, height: 18)
            layoutSelectableText(
                in: NSRect(x: contentFrame.minX + 12, y: 26, width: contentFrame.width - 24, height: max(20, contentFrame.height - 62)),
                allowsHorizontalScrolling: false
            )
            chipDisclosureView.frame = NSRect(x: 10, y: 5, width: 16, height: 16)
            chipDisclosureView.image = Self.symbolImage("doc.text", accessibilityDescription: "Open file")
            if actionControlInstalled {
                actionButton.title = file + (start.map { ":\($0)" } ?? "")
                actionButton.font = appKitTheme?.microFont
                actionButton.contentTintColor = appKitTheme?.textTertiary
                actionButton.alignment = .left
                actionButton.frame = NSRect(x: contentFrame.minX + 30, y: 2, width: contentFrame.width - 40, height: 22)
            }
        }
    }

    private static func directiveLabel(_ kind: CodexTranscriptDirectiveRender.Kind) -> String {
        switch kind {
        case .createdThread(let threadID, let pendingID):
            let prefix = pendingID == nil ? "Chat created" : "Worktree chat queued"
            return prefix + " · " + shortIdentifier(threadID ?? pendingID ?? "pending")
        case .gitAction(let verb, let branch, _):
            return switch verb {
            case "stage": "Staged changes"
            case "commit": "Committed"
            case "create-branch": "Created branch" + (branch.map { " \($0)" } ?? "")
            case "push": "Pushed" + (branch.map { " \($0)" } ?? "")
            default: "Git · \(verb)"
            }
        case .pullRequest(_, let branch, let isDraft):
            return "PR" + (branch.map { " · \($0)" } ?? "") + (isDraft ? " · draft" : "")
        case .codeComment(let title, _, _, _, _, _): return title
        case .unknown(let name): return "<\(name)>"
        }
    }

    private static func directiveIconName(_ kind: CodexTranscriptDirectiveRender.Kind) -> String {
        switch kind {
        case .createdThread: "arrow.triangle.branch"
        case .gitAction(let verb, _, _):
            switch verb {
            case "push": "tray.and.arrow.up"
            case "create-branch": "arrow.triangle.branch"
            case "stage": "square.stack.3d.up"
            default: "checkmark.seal"
            }
        case .pullRequest: "arrow.up.right.square"
        case .codeComment: "text.bubble"
        case .unknown: "ellipsis.curlybraces"
        }
    }

    private static func directiveTint(_ kind: CodexTranscriptDirectiveRender.Kind, theme: CodexTranscriptAppKitTheme) -> NSColor {
        if case .codeComment(_, _, _, _, _, let priority) = kind, let priority, priority <= 1 { return theme.danger }
        if case .unknown = kind { return theme.textTertiary }
        return theme.success
    }

    private static func directiveToolTip(_ kind: CodexTranscriptDirectiveRender.Kind, raw: String) -> String {
        switch kind {
        case .createdThread(_, let pendingID) where pendingID != nil: "Thread pending"
        case .unknown: raw
        default: directiveLabel(kind)
        }
    }

    private static func shortIdentifier(_ value: String) -> String {
        String((value.split(separator: "-").last.map(String.init) ?? value).prefix(8))
    }

    private func configureFooter(
        _ footer: CodexTranscriptFooterRender,
        item: CodexTranscriptRenderItem,
        theme: CodexTranscriptAppKitTheme
    ) {
        footerTimestampLabel.isHidden = footer.timestamp.isEmpty || !isHovered
        footerTimestampLabel.stringValue = footer.timestamp
        footerTimestampLabel.font = theme.microFont
        footerTimestampLabel.textColor = theme.textTertiary
        footerTimestampLabel.setAccessibilityLabel(item.accessibilityLabel)
        if footerActionControlsInstalled {
            configureFooterActions(footer, theme: theme)
        }
    }

    private func configureFooterActions(
        _ footer: CodexTranscriptFooterRender,
        theme: CodexTranscriptAppKitTheme
    ) {
        guard footerActionControlsInstalled else { return }
        footerCopyItemButton.font = theme.microFont
        footerCopyTurnButton.font = theme.microFont
        footerContextButton.font = theme.microFont
        footerCopyItemButton.contentTintColor = theme.textTertiary
        footerCopyTurnButton.contentTintColor = theme.textTertiary
        footerContextButton.contentTintColor = theme.textTertiary

        switch footer.kind {
        case .user:
            footerContextButton.image = Self.symbolImage(
                "square.and.pencil",
                accessibilityDescription: "Edit prompt"
            )
            footerContextButton.action = #selector(editUser)
            footerContextButton.toolTip = "Edit prompt"
            footerContextButton.setAccessibilityLabel("Edit prompt")
        case .finalAnswer:
            footerContextButton.image = Self.symbolImage(
                "arrow.triangle.branch",
                accessibilityDescription: "Fork chat"
            )
            footerContextButton.action = #selector(invokeForkChat)
            footerContextButton.toolTip = "Fork chat"
            footerContextButton.setAccessibilityLabel("Fork chat")
        }
    }

    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        if hovered,
           let footer = item?.footer,
           !footer.isTurnStreaming,
           let theme = appKitTheme {
            ensureFooterActionControls()
            configureFooterActions(footer, theme: theme)
        }
        updateFooterChromeVisibility()
        updateChipAppearance()
        view.needsLayout = true
    }

    private func updateChipAppearance() {
        guard chipControlsInstalled, item?.workRow != nil else { return }
        chipBackground.layer?.backgroundColor = NSColor.clear.cgColor
        chipBackground.layer?.borderWidth = 0
    }

    private func updateFooterChromeVisibility() {
        footerTimestampLabel.isHidden = item?.footer?.timestamp.isEmpty != false || !isHovered
        guard footerActionControlsInstalled else { return }
        guard let footer = item?.footer else {
            footerCopyItemButton.isHidden = true
            footerCopyTurnButton.isHidden = true
            footerContextButton.isHidden = true
            return
        }
        guard !footer.isTurnStreaming else {
            footerCopyItemButton.isHidden = true
            footerCopyTurnButton.isHidden = true
            footerContextButton.isHidden = true
            return
        }
        footerCopyTurnButton.isHidden = !isHovered
        footerCopyItemButton.isHidden = !isHovered || footer.kind != .finalAnswer
        footerContextButton.isHidden = !isHovered
            || (footer.kind == .finalAnswer && forkChat == nil)
    }

    private func layoutFooter(in frame: NSRect, trailing: Bool) {
        footerTimestampLabel.sizeToFit()
        let labelSize = footerTimestampLabel.frame.size
        let labelY = frame.midY - labelSize.height / 2
        let visibleButtons = footerActionControlsInstalled
            ? [footerCopyItemButton, footerCopyTurnButton, footerContextButton].filter { !$0.isHidden }
            : []
        let buttonWidth: CGFloat = 22
        let buttonsWidth = CGFloat(visibleButtons.count) * buttonWidth
            + CGFloat(max(visibleButtons.count - 1, 0)) * 2

        if trailing {
            let labelX = frame.maxX - labelSize.width
            footerTimestampLabel.frame = NSRect(
                x: labelX,
                y: labelY,
                width: labelSize.width,
                height: labelSize.height
            )
            var buttonX = labelX - (visibleButtons.isEmpty ? 0 : buttonsWidth + 5)
            for button in visibleButtons {
                button.frame = NSRect(x: buttonX, y: frame.midY - 10, width: buttonWidth, height: 20)
                buttonX += buttonWidth + 2
            }
        } else {
            footerTimestampLabel.frame = NSRect(
                x: frame.minX,
                y: labelY,
                width: labelSize.width,
                height: labelSize.height
            )
            var buttonX = footerTimestampLabel.frame.maxX + (visibleButtons.isEmpty ? 0 : 5)
            for button in visibleButtons {
                button.frame = NSRect(x: buttonX, y: frame.midY - 10, width: buttonWidth, height: 20)
                buttonX += buttonWidth + 2
            }
        }
    }

    private func layoutSelectableText(
        in frame: NSRect,
        allowsHorizontalScrolling: Bool,
        allowsVerticalScrolling: Bool = false
    ) {
        guard let textContainer = selectableTextView.textContainer else { return }
        textScrollView.hasVerticalScroller = allowsVerticalScrolling
        textScrollView.frame = frame
        let viewport = textScrollView.contentSize
        let documentWidth: CGFloat
        if allowsHorizontalScrolling {
            let measured = selectableTextView.attributedString().boundingRect(
                with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: max(20, viewport.height)),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            documentWidth = max(viewport.width, ceil(measured.width) + 2)
        } else {
            documentWidth = viewport.width
        }
        textContainer.containerSize = NSSize(
            width: documentWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        selectableTextView.layoutManager?.ensureLayout(for: textContainer)
        let measuredHeight = selectableTextView.layoutManager?
            .usedRect(for: textContainer).height ?? 0
        let documentHeight = allowsVerticalScrolling
            ? max(viewport.height, ceil(measuredHeight) + 2)
            : max(20, viewport.height)
        selectableTextView.minSize = NSSize(width: 0, height: viewport.height)
        selectableTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        selectableTextView.autoresizingMask = allowsHorizontalScrolling ? [] : [.width]
        selectableTextView.setFrameSize(NSSize(width: documentWidth, height: documentHeight))
    }

    private func installGlassBackground(theme: CodexAgentTheme) {
        clearGlassBackground()
        let surface = CodexTranscriptGlassSurface()
            .codexAgentTheme(theme)
        let host = NSHostingView(rootView: AnyView(surface))
        host.setAccessibilityElement(false)
        view.addSubview(host, positioned: .above, relativeTo: backgroundView)
        glassBackgroundView = host
    }

    private func clearGlassBackground() {
        glassBackgroundView?.removeFromSuperview()
        glassBackgroundView = nil
    }

    private func configureDiffPanel(
        _ panel: CodexTranscriptDiffPanelRender,
        item: CodexTranscriptRenderItem,
        theme: CodexTranscriptAppKitTheme,
        swiftUITheme: CodexAgentTheme,
        preserving selection: NSRange
    ) {
        installGlassBackground(theme: swiftUITheme)
        configureDiffTabs(panel, theme: theme)
        textScrollView.isHidden = false
        textScrollView.hasHorizontalScroller = true
        textScrollView.hasVerticalScroller = true
        selectableTextView.isHorizontallyResizable = true
        selectableTextView.textContainer?.widthTracksTextView = false
        selectableTextView.configureLinkAppearance(theme: theme, automaticDetection: false)
        selectableTextView.bind(
            item.preparedText?.attributedString ?? NSAttributedString(),
            accessibilityLabel: item.accessibilityLabel,
            preserving: selection
        )
        copyButton.isHidden = false
    }

    private func configureDiffTabs(
        _ panel: CodexTranscriptDiffPanelRender,
        theme: CodexTranscriptAppKitTheme
    ) {
        clearDiffTabs()
        diffTabContainer.isHidden = false
        diffSelectedUnderline.layer?.backgroundColor = theme.accent.cgColor
        for (index, file) in panel.files.enumerated() {
            let button = NSButton(title: (file.path as NSString).lastPathComponent, target: self, action: #selector(selectDiffTab(_:)))
            button.tag = index
            button.isBordered = false
            button.bezelStyle = .inline
            button.font = theme.captionFont
            button.contentTintColor = index == panel.selectedFileIndex ? theme.textPrimary : theme.textTertiary
            button.alignment = .center
            button.lineBreakMode = .byTruncatingMiddle
            button.setAccessibilityLabel("Show diff for \(file.path)")
            diffTabContainer.addSubview(button)
            diffTabButtons.append(button)
        }
        diffTabContainer.addSubview(diffSelectedUnderline, positioned: .above, relativeTo: nil)
    }

    private func clearDiffTabs() {
        guard diffControlsInstalled else { return }
        diffTabButtons.forEach { $0.removeFromSuperview() }
        diffTabButtons.removeAll(keepingCapacity: true)
        diffSelectedUnderline.removeFromSuperview()
        diffTabContainer.isHidden = true
    }

    private func layoutDiffPanel(
        _ panel: CodexTranscriptDiffPanelRender,
        in contentFrame: NSRect
    ) {
        let headerHeight: CGFloat = 36
        diffTabContainer.frame = NSRect(
            x: contentFrame.minX,
            y: contentFrame.maxY - headerHeight,
            width: contentFrame.width,
            height: headerHeight
        )
        let copyReserve: CGFloat = 42
        let availableWidth = max(80, contentFrame.width - copyReserve)
        let tabWidth = min(190, max(92, availableWidth / CGFloat(max(1, panel.files.count))))
        var x: CGFloat = 8
        for (index, button) in diffTabButtons.enumerated() {
            let width = min(tabWidth, max(70, availableWidth - x))
            button.frame = NSRect(x: x, y: 5, width: width, height: 28)
            if index == panel.selectedFileIndex {
                diffSelectedUnderline.frame = NSRect(x: x + 4, y: 1, width: max(12, width - 8), height: 2)
            }
            x += width
            if x >= availableWidth { break }
        }
        copyButton.frame = NSRect(x: contentFrame.maxX - 36, y: contentFrame.maxY - 32, width: 28, height: 26)
        layoutSelectableText(
            in: NSRect(
                x: contentFrame.minX + 12,
                y: 10,
                width: contentFrame.width - 24,
                height: max(40, contentFrame.height - headerHeight - 18)
            ),
            allowsHorizontalScrolling: true,
            allowsVerticalScrolling: true
        )
    }

    @objc private func selectDiffTab(_ sender: NSButton) {
        guard let rowID = item?.diffPanel?.rowID else { return }
        performAction?(.selectDiffFile(rowID: rowID, index: sender.tag))
    }

    private func configureAgentChips(
        _ chips: [CodexTranscriptAgentChipRender],
        theme _: CodexTranscriptAppKitTheme,
        swiftUITheme: CodexAgentTheme
    ) {
        let canReuseHosts = agentChipHosts.count == chips.count
            && configuredAgentChips.map(\.id) == chips.map(\.id)
        if !canReuseHosts { clearAgentChips() }
        configuredAgentChips = chips
        agentChipContainer.isHidden = false

        if canReuseHosts {
            for (index, chip) in chips.enumerated() {
                let host = agentChipHosts[index]
                host.rootView = agentPillView(chip, index: index, swiftUITheme: swiftUITheme)
                configureAgentChipAccessibility(host, chip: chip)
            }
            return
        }

        for (index, chip) in chips.enumerated() {
            let host = NSHostingView(rootView: agentPillView(chip, index: index, swiftUITheme: swiftUITheme))
            configureAgentChipAccessibility(host, chip: chip)
            agentChipContainer.addSubview(host)
            agentChipHosts.append(host)
            agentChipHostCreationCount += 1
        }
    }

    private func agentPillView(
        _ chip: CodexTranscriptAgentChipRender,
        index: Int,
        swiftUITheme: CodexAgentTheme
    ) -> AnyView {
        let isAttachment = chip.threadID == nil && chip.taskSummary != nil
        let isResponseAnnotation = chip.systemImage == "text.bubble"
        let pill = CodexTranscriptAgentPill(
            chip: chip,
            onHover: { [weak self] hovered in
                guard !isAttachment || isResponseAnnotation else {
                    if hovered { self?.closeAgentPreview() }
                    return
                }
                self?.setAgentPreviewHover(hovered, index: index)
            },
            onOpen: { [weak self] in
                if let source = chip.taskSummary,
                   let path = CodexTranscriptImageSource.localFilePath(source),
                   isAttachment {
                    CodexTranscriptQuickLookController.shared.present(URL(fileURLWithPath: path))
                } else if let threadID = chip.threadID {
                    self?.performAction?(.openSubagent(threadID: threadID))
                }
            }
        )
        return AnyView(pill.codexAgentTheme(swiftUITheme))
    }

    private func configureAgentChipAccessibility(
        _ host: NSHostingView<AnyView>,
        chip: CodexTranscriptAgentChipRender
    ) {
        let isAttachment = chip.threadID == nil && chip.taskSummary != nil
        host.setAccessibilityLabel(
            isAttachment ? chip.label : "\(chip.label), \(chip.status.transcriptLabel)"
        )
    }

    private func layoutAgentChips(
        _ chips: [CodexTranscriptAgentChipRender],
        in contentFrame: NSRect,
        theme: CodexTranscriptAppKitTheme
    ) {
        agentChipContainer.frame = contentFrame
        let height = max(26, chips.compactMap {
            $0.attachmentKind == .image ? $0.imagePreviewHeight : nil
        }.max() ?? 0)
        let gap: CGFloat = 6
        var x: CGFloat = 0
        var y = contentFrame.height - height
        for (chip, host) in zip(chips, agentChipHosts) {
            let title = chip.threadID == nil
                ? chip.label
                : "\(chip.label) · \(chip.status.transcriptLabel.lowercased())"
            let labelWidth = ceil((title as NSString).size(withAttributes: [.font: theme.captionFont]).width)
            let isImage = chip.attachmentKind == .image
            let width = isImage
                ? chip.imagePreviewSize
                : min(contentFrame.width, max(74, labelWidth + 28))
            if x > 0, x + width > contentFrame.width {
                x = 0
                y -= height + gap
            }
            host.frame = NSRect(x: x, y: max(0, y), width: width, height: height)
            x += width + gap
        }
    }

    private func clearAgentChips() {
        guard agentControlsInstalled else { return }
        agentChipHosts.forEach { $0.removeFromSuperview() }
        agentChipHosts.removeAll(keepingCapacity: true)
        configuredAgentChips.removeAll(keepingCapacity: true)
        agentChipContainer.isHidden = true
    }

    private func setAgentPreviewHover(_ hovered: Bool, index: Int) {
        agentPreviewCloseTask?.cancel()
        guard hovered else {
            scheduleAgentPreviewClose()
            return
        }
        guard configuredAgentChips.indices.contains(index),
              agentChipHosts.indices.contains(index),
              view.window != nil else { return }
        showAgentPreview(configuredAgentChips[index], relativeTo: agentChipHosts[index])
    }

    private func showAgentPreview(
        _ chip: CodexTranscriptAgentChipRender,
        relativeTo anchor: NSView
    ) {
        closeAgentPreview()
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = true
        let preview = CodexTranscriptAgentHoverPreview(
            chip: chip,
            onHover: { [weak self] hovered in
                self?.pointerIsInsideAgentPreview = hovered
                if !hovered { self?.scheduleAgentPreviewClose() }
            },
            onOpen: { [weak self] in
                guard let threadID = chip.threadID else { return }
                self?.performAction?(.openSubagent(threadID: threadID))
                self?.closeAgentPreview()
            }
        )
        popover.contentViewController = NSHostingController(
            rootView: AnyView(preview.codexAgentTheme(swiftUITheme))
        )
        let hasDetails = chip.taskSummary != nil || chip.latestUpdate != nil
        let isResponseAnnotation = chip.systemImage == "text.bubble"
        popover.contentSize = NSSize(
            width: 300,
            height: isResponseAnnotation ? 210 : (hasDetails ? 142 : 92)
        )
        agentPreviewPopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    private func scheduleAgentPreviewClose() {
        let task = DispatchWorkItem { [weak self] in
            guard let self, !self.pointerIsInsideAgentPreview else { return }
            self.closeAgentPreview()
        }
        agentPreviewCloseTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: task)
    }

    private func closeAgentPreview() {
        agentPreviewCloseTask?.cancel()
        agentPreviewCloseTask = nil
        agentPreviewPopover?.close()
        agentPreviewPopover = nil
        pointerIsInsideAgentPreview = false
    }

    func updateWorkingHeader(at date: Date) {
        guard actionControlInstalled, let header = item?.workHeader else { return }
        actionButton.title = Self.workHeaderTitle(header, at: date)
        view.needsLayout = true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let id = item?.id else { return }
        selectionChanged?(id, selectableTextView.selectedRange().length > 0)
        updateAddSelectionToChatButton()
        view.needsLayout = true
    }

    private func updateResponseAnnotationChrome() {
        guard textControlsInstalled, let item, item.allowsResponseAnnotation else {
            if textControlsInstalled {
                clearResponseAnnotationHighlights()
                closeResponseSelectionAction()
            }
            return
        }

        clearResponseAnnotationHighlights()
        let matching = responseAnnotations.filter {
            $0.anchor.renderItemID == item.id.rawValue
                && $0.anchor.range.location != NSNotFound
                && NSMaxRange($0.anchor.range) <= (selectableTextView.textStorage?.length ?? 0)
                && $0.anchor.range.length > 0
        }
        for annotation in matching {
            selectableTextView.layoutManager?.addTemporaryAttribute(
                .backgroundColor,
                value: (appKitTheme?.accent ?? .controlAccentColor).withAlphaComponent(0.28),
                forCharacterRange: annotation.anchor.range
            )
        }
        configureResponseAnnotationMarkers(matching)
        updateAddSelectionToChatButton()
    }

    private func clearResponseAnnotationHighlights() {
        let length = selectableTextView.textStorage?.length ?? 0
        guard length > 0 else { return }
        selectableTextView.layoutManager?.removeTemporaryAttribute(
            .backgroundColor,
            forCharacterRange: NSRange(location: 0, length: length)
        )
    }

    private func updateAddSelectionToChatButton() {
        guard textControlsInstalled,
              item?.allowsResponseAnnotation == true,
              pendingResponseAnnotation == nil,
              selectedResponseText() != nil
        else {
            closeResponseSelectionAction()
            return
        }
        showResponseSelectionAction()
    }

    private func configureResponseAnnotationMarkers(
        _ annotations: [CodexResponseTextAnnotation]
    ) {
        clearResponseAnnotationMarkers()
        for annotation in annotations {
            guard let ordinal = responseAnnotations.firstIndex(where: { $0.id == annotation.id }) else {
                continue
            }
            let button = CodexResponseAnnotationMarkerButton(frame: .zero)
            button.title = "\(ordinal + 1)"
            button.markerColor = appKitTheme?.accent ?? .controlAccentColor
            button.target = self
            button.action = #selector(openResponseAnnotationEditor(_:))
            button.tag = ordinal
            button.toolTip = annotation.annotation ?? annotation.text
            button.setAccessibilityLabel("Annotation \(ordinal + 1)")
            responseAnnotationMarkerButtons.append(button)
            view.addSubview(button)
        }
    }

    private func clearResponseAnnotationMarkers() {
        responseAnnotationMarkerButtons.forEach { $0.removeFromSuperview() }
        responseAnnotationMarkerButtons.removeAll(keepingCapacity: true)
    }

    private func layoutResponseAnnotationChrome() {
        guard textControlsInstalled else { return }
        positionResponseSelectionActionPanel()

        let matching = responseAnnotations.filter {
            $0.anchor.renderItemID == item?.id.rawValue
                && $0.anchor.range.location != NSNotFound
                && NSMaxRange($0.anchor.range) <= (selectableTextView.textStorage?.length ?? 0)
                && $0.anchor.range.length > 0
        }
        for (button, annotation) in zip(responseAnnotationMarkerButtons, matching) {
            guard let markerRect = textRect(for: annotation.anchor.range) else { continue }
            let rect = selectableTextView.convert(markerRect, to: view)
            let size: CGFloat = 25
            let proposedY = view.isFlipped ? rect.minY - size : rect.maxY
            button.frame = NSRect(
                x: min(max(0, rect.maxX - size / 2), max(0, view.bounds.width - size)),
                y: min(max(0, proposedY), max(0, view.bounds.height - size)),
                width: size,
                height: size
            )
        }
    }

    private func textRect(for characterRange: NSRange) -> NSRect? {
        guard characterRange.location != NSNotFound,
              characterRange.length > 0,
              let layoutManager = selectableTextView.layoutManager,
              let textContainer = selectableTextView.textContainer,
              NSMaxRange(characterRange) <= (selectableTextView.textStorage?.length ?? 0)
        else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += selectableTextView.textContainerOrigin.x
        rect.origin.y += selectableTextView.textContainerOrigin.y
        return rect
    }

    @objc private func addSelectionToChat() {
        guard let item, item.allowsResponseAnnotation,
              let selection = selectedResponseText()
        else { return }

        let annotation = CodexResponseTextAnnotation(
            text: selection.text,
            anchor: CodexResponseTextAnchor(
                renderItemID: item.id.rawValue,
                startOffset: selection.range.location,
                endOffset: NSMaxRange(selection.range)
            )
        )
        pendingResponseAnnotation = annotation
        closeResponseSelectionAction()
        showResponseAnnotationEditor(annotation, isCreating: true)
    }

    private func selectedResponseText() -> (range: NSRange, text: String)? {
        let range = selectableTextView.selectedRange()
        guard range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= (selectableTextView.textStorage?.length ?? 0)
        else { return nil }
        let text = (selectableTextView.string as NSString)
            .substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (range, text)
    }

    private func dismissResponseSelectionAction() {
        closeResponseSelectionAction()
        selectableTextView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    private func showResponseSelectionAction() {
        guard let parentWindow = view.window,
              textRect(for: selectableTextView.selectedRange()) != nil
        else {
            closeResponseSelectionAction()
            return
        }

        if responseSelectionActionPanel == nil {
            let host = NSHostingView(rootView: responseSelectionActionView())
            host.layoutSubtreeIfNeeded()
            let fittingSize = host.fittingSize
            let panelSize = NSSize(
                width: ceil(max(1, fittingSize.width)),
                height: ceil(max(1, fittingSize.height))
            )
            host.frame = NSRect(origin: .zero, size: panelSize)

            let panel = CodexResponseSelectionActionPanel(
                contentRect: NSRect(origin: .zero, size: panelSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.isFloatingPanel = true
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .utilityWindow
            panel.contentView = host

            responseSelectionActionPanel = panel
            parentWindow.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
            installResponseSelectionActionEventMonitor(panel)
        }

        positionResponseSelectionActionPanel()
    }

    private func positionResponseSelectionActionPanel() {
        guard let panel = responseSelectionActionPanel,
              let parentWindow = view.window,
              let selectionRect = textRect(for: selectableTextView.selectedRange())
        else { return }

        let selectionInScreen = parentWindow.convertToScreen(
            selectableTextView.convert(selectionRect, to: nil)
        )
        let placementFrame = (
            parentWindow.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? parentWindow.frame
        ).insetBy(dx: 8, dy: 8)
        let panelSize = panel.frame.size
        let above = selectionInScreen.maxY + 8
        let below = selectionInScreen.minY - panelSize.height - 8
        let proposedY = above + panelSize.height <= placementFrame.maxY ? above : below
        let origin = NSPoint(
            x: min(
                max(placementFrame.minX, selectionInScreen.minX),
                max(placementFrame.minX, placementFrame.maxX - panelSize.width)
            ),
            y: min(
                max(placementFrame.minY, proposedY),
                max(placementFrame.minY, placementFrame.maxY - panelSize.height)
            )
        )
        panel.setFrameOrigin(origin)
    }

    private func closeResponseSelectionAction() {
        if let monitor = responseSelectionActionEventMonitor {
            NSEvent.removeMonitor(monitor)
            responseSelectionActionEventMonitor = nil
        }
        guard let panel = responseSelectionActionPanel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        responseSelectionActionPanel = nil
    }

    private func installResponseSelectionActionEventMonitor(
        _ panel: CodexResponseSelectionActionPanel
    ) {
        responseSelectionActionEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        ) { [weak self, weak panel] event in
            guard let self, let panel else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.dismissResponseSelectionAction()
                return nil
            }
            if event.type == .scrollWheel {
                self.dismissResponseSelectionAction()
            } else if event.type != .keyDown, event.window !== panel {
                self.dismissResponseSelectionAction()
            }
            return event
        }
    }

    @objc private func openResponseAnnotationEditor(_ sender: NSButton) {
        guard responseAnnotations.indices.contains(sender.tag) else { return }
        let annotation = responseAnnotations[sender.tag]
        showResponseAnnotationEditor(annotation, isCreating: false)
    }

    private func showResponseAnnotationEditor(
        _ annotation: CodexResponseTextAnnotation,
        isCreating: Bool
    ) {
        closeResponseAnnotationEditor()
        guard let parentWindow = view.window else { return }
        let anchorRect: NSRect?
        if isCreating, let selectionRect = textRect(for: annotation.anchor.range) {
            anchorRect = selectableTextView.convert(selectionRect, to: view)
        } else if let ordinal = responseAnnotations.firstIndex(where: { $0.id == annotation.id }),
                  let marker = responseAnnotationMarkerButtons.first(where: { $0.tag == ordinal }) {
            anchorRect = marker.frame
        } else {
            anchorRect = nil
        }
        guard let anchorRect else { return }

        let panelSize = NSSize(width: 294, height: 44)
        let panel = CodexResponseAnnotationEditorPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.contentView = NSHostingView(rootView: AnyView(
            CodexResponseAnnotationNoteEditor(
                initialNote: annotation.annotation ?? "",
                isCreating: isCreating,
                onSave: { [weak self] note in
                    self?.saveResponseAnnotation(id: annotation.id, note: note)
                },
                onDelete: { [weak self] in
                    self?.deleteResponseAnnotation(annotation.id)
                }
            )
            .codexAgentTheme(swiftUITheme)
        ))
        panel.setFrameOrigin(responseAnnotationEditorOrigin(
            anchorRect: anchorRect,
            panelSize: panelSize,
            parentWindow: parentWindow
        ))
        responseAnnotationEditorPanel = panel
        responseAnnotationEditorID = annotation.id
        responseAnnotationEditorIsCreating = isCreating
        parentWindow.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        installResponseAnnotationEditorEventMonitor(panel)
    }

    private func closeResponseAnnotationEditor() {
        if let monitor = responseAnnotationEditorEventMonitor {
            NSEvent.removeMonitor(monitor)
            responseAnnotationEditorEventMonitor = nil
        }
        guard let panel = responseAnnotationEditorPanel else { return }
        let parent = panel.parent
        let restoresParentFocus = panel.isKeyWindow
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        responseAnnotationEditorPanel = nil
        responseAnnotationEditorID = nil
        responseAnnotationEditorIsCreating = false
        if restoresParentFocus {
            parent?.makeKey()
        }
    }

    private func installResponseAnnotationEditorEventMonitor(
        _ panel: CodexResponseAnnotationEditorPanel
    ) {
        responseAnnotationEditorEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self, weak panel] event in
            guard let self, let panel else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                let id = self.responseAnnotationEditorID
                let shouldDelete = self.responseAnnotationEditorIsCreating
                self.closeResponseAnnotationEditor()
                if shouldDelete, let id {
                    self.deleteResponseAnnotation(id)
                }
                return nil
            }
            if event.type != .keyDown, event.window !== panel {
                if self.responseAnnotationEditorIsCreating {
                    self.pendingResponseAnnotation = nil
                    self.selectableTextView.setSelectedRange(NSRange(location: 0, length: 0))
                }
                self.closeResponseAnnotationEditor()
            }
            return event
        }
    }

    private func responseAnnotationEditorOrigin(
        anchorRect: NSRect,
        panelSize: NSSize,
        parentWindow: NSWindow
    ) -> NSPoint {
        let anchorInWindow = view.convert(anchorRect, to: nil)
        let convertedCenter = parentWindow.convertPoint(toScreen: NSPoint(
            x: anchorInWindow.midX,
            y: anchorInWindow.midY
        ))
        let parentFrame = parentWindow.frame
        let placementFrame = parentFrame.origin.x.isFinite
            && parentFrame.origin.y.isFinite
            && parentFrame.width.isFinite
            && parentFrame.height.isFinite
            && parentFrame.width >= panelSize.width + 32
            && parentFrame.height >= panelSize.height + 32
            ? parentFrame
            : (parentWindow.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1_024, height: 768))
        let bounds = placementFrame.insetBy(dx: 16, dy: 16)
        let markerCenter = NSPoint(
            x: convertedCenter.x.isFinite ? convertedCenter.x : bounds.midX,
            y: convertedCenter.y.isFinite ? convertedCenter.y : bounds.midY
        )
        let right = markerCenter.x + 27
        let left = markerCenter.x - 27 - panelSize.width
        let x: CGFloat
        if right + panelSize.width <= bounds.maxX {
            x = right
        } else if left >= bounds.minX {
            x = left
        } else {
            x = min(max(bounds.minX, markerCenter.x - panelSize.width / 2), bounds.maxX - panelSize.width)
        }
        let y = min(
            max(bounds.minY, markerCenter.y - panelSize.height / 2),
            bounds.maxY - panelSize.height
        )
        return NSPoint(x: x, y: y)
    }

    private func deleteResponseAnnotation(_ id: String) {
        if pendingResponseAnnotation?.id == id {
            pendingResponseAnnotation = nil
            selectableTextView.setSelectedRange(NSRange(location: 0, length: 0))
            closeResponseAnnotationEditor()
            updateAddSelectionToChatButton()
            return
        }
        responseAnnotations.removeAll { $0.id == id }
        removeResponseAnnotation?(id)
        closeResponseAnnotationEditor()
        updateResponseAnnotationChrome()
        view.needsLayout = true
    }

    private func saveResponseAnnotation(id: String, note: String) {
        if var annotation = pendingResponseAnnotation, annotation.id == id {
            annotation.annotation = note
            pendingResponseAnnotation = nil
            responseAnnotations.append(annotation)
            upsertResponseAnnotation?(annotation)
            selectableTextView.setSelectedRange(NSRange(location: 0, length: 0))
            closeResponseAnnotationEditor()
            updateResponseAnnotationChrome()
            view.needsLayout = true
            return
        }
        guard let index = responseAnnotations.firstIndex(where: { $0.id == id }) else {
            return
        }
        responseAnnotations[index].annotation = note
        upsertResponseAnnotation?(responseAnnotations[index])
        closeResponseAnnotationEditor()
        updateResponseAnnotationChrome()
        view.needsLayout = true
    }

    @objc private func invokePrimaryAction() {
        guard let action = item?.action else { return }
        performAction?(action)
    }

    @objc private func allowApproval() {
        guard let requestID = item?.approval?.requestID else { return }
        performAction?(.resolveApproval(requestID: requestID, approve: true))
    }

    @objc private func denyApproval() {
        guard let requestID = item?.approval?.requestID else { return }
        performAction?(.resolveApproval(requestID: requestID, approve: false))
    }

    @objc private func copyItem(_ sender: Any?) {
        guard let text = item?.copyPayload?.materialized() else { return }
        copy?(text)
        if let button = sender as? NSButton { flashCopyConfirmation(button) }
    }

    @objc private func copySelectionOrItem() {
        if textControlsInstalled, selectableTextView.selectedRange().length > 0 {
            selectableTextView.copy(nil)
        } else {
            copyItem(nil)
        }
    }

    @objc private func copyTurn(_ sender: Any?) {
        guard let text = item?.copyTurnText else { return }
        copy?(text)
        if let button = sender as? NSButton { flashCopyConfirmation(button) }
    }

    @objc private func editUser() {
        guard let item,
              item.textRole == .user || item.footer?.kind == .user,
              let text = item.editUserText ?? item.copyText else { return }
        editUserMessage?(text)
    }

    @objc private func invokeForkChat() {
        forkChat?()
    }

    @objc private func invokeRetryTurn() {
        guard let message = item?.retryUserMessage else { return }
        retryTurn?(message)
    }

    @objc private func openContextFile() {
        guard let contextFileReference else { return }
        fileNavigationService.open(contextFileReference)
    }

    @objc private func revealContextFile() {
        guard let contextFileReference else { return }
        fileNavigationService.reveal(contextFileReference)
    }

    @objc private func copyContextFilePath() {
        guard let contextFileReference else { return }
        copy?(contextFileReference.reference.path)
    }

    func textView(
        _ textView: NSTextView,
        clickedOnLink link: Any,
        at charIndex: Int
    ) -> Bool {
        guard let reference = CodexTranscriptFileCitationLink.reference(from: link),
              let resolved = fileNavigationService.resolve(reference) else { return false }
        fileNavigationService.open(resolved)
        return true
    }

    private func makeTextContextMenu(for event: NSEvent) -> NSMenu? {
        let point = selectableTextView.convert(event.locationInWindow, from: nil)
        let index = selectableTextView.characterIndexForInsertion(at: point)
        if index < (selectableTextView.textStorage?.length ?? 0),
           let value = selectableTextView.textStorage?.attribute(
               .link,
               at: index,
               effectiveRange: nil
           ),
           let reference = CodexTranscriptFileCitationLink.reference(from: value),
           let resolved = fileNavigationService.resolve(reference) {
            contextFileReference = resolved
            let menu = NSMenu()
            menu.addItem(withTitle: "Open", action: #selector(openContextFile), keyEquivalent: "")
            menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealContextFile), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Copy path", action: #selector(copyContextFilePath), keyEquivalent: "")
            for menuItem in menu.items { menuItem.target = self }
            return menu
        }
        contextFileReference = nil
        return makeContextMenu()
    }

    private func makeContextMenu() -> NSMenu? {
        guard let item else { return nil }
        let menu = NSMenu()
        if item.copyPayload != nil {
            let title: String = if item.code != nil { "Copy code" }
                else if item.textRole == .expandedOutput { "Copy output" }
                else if item.textRole == .finalAnswer || item.footer?.kind == .finalAnswer { "Copy final answer" }
                else { "Copy" }
            let action = item.code != nil || item.textRole == .expandedOutput || item.footer != nil
                ? #selector(copyItem(_:))
                : #selector(copySelectionOrItem)
            menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        }
        if item.allowsResponseAnnotation,
           textControlsInstalled,
           selectableTextView.selectedRange().length > 0 {
            menu.addItem(
                withTitle: "Add to chat",
                action: #selector(addSelectionToChat),
                keyEquivalent: ""
            )
        }
        menu.addItem(withTitle: "Copy turn", action: #selector(copyTurn(_:)), keyEquivalent: "")
        if item.textRole == .user || item.footer?.kind == .user {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Edit message", action: #selector(editUser), keyEquivalent: "")
        }
        if (item.textRole == .finalAnswer || item.footer?.kind == .finalAnswer), forkChat != nil {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Fork chat", action: #selector(invokeForkChat), keyEquivalent: "")
        }
        if item.retryUserMessage != nil, retryTurn != nil {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Retry turn", action: #selector(invokeRetryTurn), keyEquivalent: "")
        }
        for menuItem in menu.items { menuItem.target = self }
        return menu
    }

    private func flashCopyConfirmation(_ button: NSButton) {
        let key = ObjectIdentifier(button)
        let token = UUID()
        let originalImage = button.image
        let originalTint = button.contentTintColor
        copyConfirmationTokens[key] = token
        button.image = Self.symbolImage("checkmark", accessibilityDescription: "Copied")
        button.contentTintColor = appKitTheme?.success
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, weak button] in
            guard let self, let button, self.copyConfirmationTokens[key] == token else { return }
            self.copyConfirmationTokens.removeValue(forKey: key)
            button.image = originalImage
            button.contentTintColor = originalTint ?? self.appKitTheme?.textTertiary
        }
    }

    private func resetCopyConfirmation(
        _ button: NSButton,
        imageName: String,
        accessibilityDescription: String
    ) {
        copyConfirmationTokens.removeValue(forKey: ObjectIdentifier(button))
        button.image = Self.symbolImage(imageName, accessibilityDescription: accessibilityDescription)
        button.contentTintColor = appKitTheme?.textTertiary
    }

    private static let symbolImageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    private static func symbolImage(
        _ name: String,
        accessibilityDescription: String
    ) -> NSImage? {
        let key = "\(name)\u{0}\(accessibilityDescription)" as NSString
        if let cached = symbolImageCache.object(forKey: key) { return cached }
        guard let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: accessibilityDescription
        ) else { return nil }
        symbolImageCache.setObject(image, forKey: key)
        return image
    }

    private static func workHeaderTitle(_ header: CodexTranscriptWorkHeaderRender, at date: Date) -> String {
        switch header.state {
        case .working(let startedAt, let showsDuration):
            return showsDuration ? "Working for \(max(0, Int(date.timeIntervalSince(startedAt))))s" : "Thinking"
        case .done(let durationMs, let isExpanded):
            _ = isExpanded
            return CodexWorkBlockViewV2.completedLabel(durationMs)
        case .interrupted(let durationMs, let message):
            let elapsed = durationMs.map { " after \(CodexWorkBlockViewV2.duration($0))" } ?? ""
            return "Interrupted\(elapsed)" + (message.isEmpty ? "" : ": \(message)")
        case .failed(let message):
            return message.isEmpty ? "Work failed" : message
        }
    }

    private static func workHeaderDisclosureImage(_ header: CodexTranscriptWorkHeaderRender) -> NSImage? {
        guard case .done(_, let isExpanded) = header.state else { return nil }
        return symbolImage(
            isExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: isExpanded ? "Collapse work" : "Expand work"
        )
    }

    private static func workRowTitle(
        _ row: CodexTranscriptWorkRowRender,
        theme: CodexTranscriptAppKitTheme
    ) -> NSAttributedString {
        let glyph = codexStatusGlyphV2(row.status)
        let duration = row.durationMs.map { "  " + CodexWorkBlockViewV2.duration($0) } ?? ""
        let disclosure = row.isSubagentLink ? "  ↗" : (row.hasDetail ? (row.isExpanded ? "  ⌄" : "  ›") : "")
        let result = NSMutableAttributedString(string: glyph, attributes: [
            .font: theme.captionFont,
            .foregroundColor: statusColor(row.status, theme: theme)
        ])
        result.append(NSAttributedString(
            string: "  \(row.label)\(duration)\(disclosure)",
            attributes: [.font: theme.captionFont, .foregroundColor: theme.textTertiary]
        ))
        return result
    }

    private static func chipIconName(_ row: CodexTranscriptWorkRowRender) -> String {
        if let systemImage = row.systemImage, !systemImage.isEmpty { return systemImage }
        switch row.status {
        case .failed, .declined, .unknown:
            return "exclamationmark.triangle"
        case .inProgress, .completed:
            break
        }
        return switch row.kind {
        case .command: "terminal"
        case .fileChange: "doc.text"
        case .mcp: "app.connected.to.app.below.fill"
        case .webSearch: "magnifyingglass"
        case .agent: "person.2"
        case .other: row.status == .inProgress ? "arrow.triangle.2.circlepath" : "checkmark.circle"
        }
    }

    private static func chipIconAccessibilityDescription(_ row: CodexTranscriptWorkRowRender) -> String {
        switch row.status {
        case .inProgress: "In progress"
        case .completed: "Completed"
        case .failed: "Failed"
        case .declined: "Declined"
        case .unknown: "Unknown status"
        }
    }

    private static func chipDisclosureImage(
        _ row: CodexTranscriptWorkRowRender,
        isActionable: Bool
    ) -> NSImage? {
        guard isActionable else { return nil }
        let name = row.isSubagentLink ? "arrow.up.right" : (row.isExpanded ? "chevron.down" : "chevron.right")
        return symbolImage(
            name,
            accessibilityDescription: row.isSubagentLink ? "Open agent" : "Show details"
        )
    }

    private var visibleChipLabelMaxX: CGFloat {
        let font = chipLabel.font ?? appKitTheme?.captionFont ?? NSFont.systemFont(ofSize: 12)
        let width = ceil((chipLabel.stringValue as NSString).size(
            withAttributes: [.font: font]
        ).width)
        return chipLabel.frame.minX + min(width, chipLabel.frame.width)
    }

    private static func statusColor(
        _ status: CodexWorkItemStatusV2,
        theme: CodexTranscriptAppKitTheme
    ) -> NSColor {
        switch status {
        case .inProgress: theme.running
        case .completed: theme.success
        case .failed: theme.danger
        case .declined, .unknown: theme.warning
        }
    }

    private static func workStatusTitle(_ row: CodexTranscriptWorkRowRender) -> String {
        if row.kind == .command {
            switch row.status {
            case .inProgress: return "running"
            case .completed:
                if let exitCode = row.exitCode {
                    return exitCode == 0 ? "succeeded · exit 0" : "failed · exit \(exitCode)"
                }
                return "finished"
            case .failed:
                return row.exitCode.map { "failed · exit \($0)" } ?? "failed"
            case .declined: return "stopped"
            case .unknown: return "status unknown"
            }
        }
        return workStatusTitle(row.status)
    }

    private static func workStatusTitle(_ status: CodexWorkItemStatusV2) -> String {
        switch status {
        case .inProgress: "running"
        case .completed: "finished"
        case .failed: "failed"
        case .declined: "declined"
        case .unknown: "status unknown"
        }
    }

    private static func paragraphStyle(_ theme: CodexTranscriptAppKitTheme) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = theme.lineSpacing
        return style
    }

    private static func backgroundColor(item: CodexTranscriptRenderItem, theme: CodexTranscriptAppKitTheme) -> NSColor {
        if item.textRole == .user { return theme.userBubble }
        if item.code != nil { return theme.codeBackground }
        return theme.surfaceSunken.withAlphaComponent(0.65)
    }

    private static func borderColor(item: CodexTranscriptRenderItem, theme: CodexTranscriptAppKitTheme) -> NSColor {
        item.textRole == .user ? theme.userBubbleStroke : theme.border
    }
}

private struct CodexTranscriptGlassSurface: View {
    @Environment(\.codexAgentTheme) private var theme

    var body: some View {
        Color.clear
            .codexGlass(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous), role: .panel)
    }
}

@MainActor
private final class CodexTranscriptQuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = CodexTranscriptQuickLookController()

    private var previewURL: URL?

    func present(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path),
              let panel = QLPreviewPanel.shared()
        else { return }
        previewURL = url
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        (previewURL ?? URL(fileURLWithPath: "/")) as NSURL
    }
}

private struct CodexTranscriptAgentPill: View {
    @Environment(\.codexAgentTheme) private var theme

    let chip: CodexTranscriptAgentChipRender
    let onHover: (Bool) -> Void
    let onOpen: () -> Void

    var body: some View {
        let imageAttachment = chip.attachmentKind == .image
        let canOpenAttachment = chip.taskSummary
            .flatMap(CodexTranscriptImageSource.localFilePath) != nil
        HStack(spacing: 5) {
            if imageAttachment {
                if let source = chip.taskSummary {
                    CodexTranscriptImageThumbnail(
                        source: source,
                        label: chip.label,
                        side: chip.imagePreviewSize,
                        aspectRatio: chip.imagePreviewAspectRatio
                    )
                } else {
                    VStack(spacing: 3) {
                        Image(systemName: "photo")
                            .font(theme.fonts.chat.weight(.medium))
                            .foregroundStyle(theme.colors.textSecondary)
                        Text(chip.label)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(theme.colors.textTertiary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .padding(5)
                    .frame(width: chip.imagePreviewSize, height: chip.imagePreviewHeight)
                    .background(theme.colors.surface.opacity(0.7))
                }
            } else if chip.threadID == nil {
                Image(systemName: chip.systemImage ?? "doc")
                    .font(theme.fonts.chipLabel)
                    .foregroundStyle(theme.colors.textSecondary)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
            }
            if !imageAttachment {
                Text(chip.label)
                    .foregroundStyle(theme.colors.textPrimary)
            }
            if chip.threadID != nil {
                Text("· \(statusTitle.lowercased())")
                    .foregroundStyle(theme.colors.textSecondary)
            }
        }
        .font(theme.fonts.caption)
        .lineLimit(imageAttachment ? 2 : 1)
        .padding(.horizontal, imageAttachment ? 0 : 8)
        .frame(height: imageAttachment ? chip.imagePreviewHeight : 26)
        .contentShape(Capsule())
        .modifier(CodexTranscriptAgentPillChrome(
            isImageAttachment: imageAttachment,
            tint: chip.threadID == nil
                ? theme.colors.surfaceElevated.opacity(0.45)
                : statusColor.opacity(0.055),
            isInteractive: chip.threadID != nil || canOpenAttachment
        ))
        .onTapGesture(perform: onOpen)
        .onHover(perform: onHover)
        .help(chip.threadID == nil ? chip.label : "\(chip.label) — \(statusTitle)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(chip.label), \(statusTitle)")
        .accessibilityAddTraits(chip.threadID != nil || canOpenAttachment ? .isButton : [])
    }

    private var statusTitle: String {
        chip.status.transcriptLabel
    }

    private var statusColor: Color {
        switch chip.status {
        case .starting: theme.colors.warning
        case .working: theme.colors.running
        case .done: theme.colors.success
        case .failed: theme.colors.danger
        case .closed: theme.colors.textTertiary
        }
    }
}

private struct CodexTranscriptAgentPillChrome: ViewModifier {
    let isImageAttachment: Bool
    let tint: Color
    let isInteractive: Bool

    @Environment(\.codexAgentTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if isImageAttachment {
            content
        } else {
            content
                .background(tint, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(
                            isInteractive
                                ? theme.colors.borderStrong.opacity(0.65)
                                : theme.colors.border.opacity(0.65),
                            lineWidth: 1
                        )
                }
        }
    }
}

private struct CodexTranscriptAgentHoverPreview: View {
    @Environment(\.codexAgentTheme) private var theme

    let chip: CodexTranscriptAgentChipRender
    let onHover: (Bool) -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isResponseAnnotation {
                Label(chip.label, systemImage: "text.bubble")
                    .font(theme.fonts.label)
            } else {
                HStack(spacing: 7) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(chip.label).font(theme.fonts.label)
                    Spacer(minLength: 8)
                    Text(statusTitle).font(theme.fonts.caption).foregroundStyle(statusColor)
                }
            }

            if let task = chip.taskSummary {
                if isResponseAnnotation {
                    Text(task)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(8)
                        .textSelection(.enabled)
                } else {
                    previewRow("Task", task)
                }
            }
            if let latest = chip.latestUpdate {
                previewRow("Latest update", latest)
            }

            if chip.threadID != nil {
                Divider().overlay(theme.colors.border)
                Button(action: onOpen) {
                    HStack {
                        Image(systemName: "arrow.up.right.square")
                        Text("Open task")
                        Spacer(minLength: 0)
                    }
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textPrimary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .onHover(perform: onHover)
    }

    private var isResponseAnnotation: Bool {
        chip.systemImage == "text.bubble"
    }

    private func previewRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textTertiary)
                .frame(width: 82, alignment: .leading)
            Text(value)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)
                .lineLimit(2)
        }
    }

    private var statusTitle: String {
        chip.status.transcriptLabel
    }

    private var statusColor: Color {
        switch chip.status {
        case .starting: theme.colors.warning
        case .working: theme.colors.running
        case .done: theme.colors.success
        case .failed: theme.colors.danger
        case .closed: theme.colors.textTertiary
        }
    }
}
