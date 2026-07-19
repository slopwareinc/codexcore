import AppKit
import SwiftUI

private final class CodexTranscriptHoverView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var usesPointingHand = false { didSet { window?.invalidateCursorRects(for: self) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
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
}

final class CodexSelectableTranscriptTextView: NSTextView {
    var onSelectionStateChange: ((Bool) -> Void)?

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

    private let selectableTextView: CodexSelectableTranscriptTextView = {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        return CodexSelectableTranscriptTextView(frame: .zero, textContainer: textContainer)
    }()
    private let textScrollView = NSScrollView()
    private let actionButton = NSButton()
    private let copyButton = NSButton()
    private let codeHeaderView = NSView()
    private let codeLanguageLabel = NSTextField(labelWithString: "")
    private let chipBackground = NSView()
    private let chipIconView = NSImageView()
    private let chipLabel = CodexShimmerTextField(frame: .zero)
    private let chipDurationLabel = NSTextField(labelWithString: "")
    private let chipStatusLabel = NSTextField(labelWithString: "")
    private let chipDisclosureView = NSImageView()
    private let agentChipContainer = NSView()
    private var agentChipHosts: [NSHostingView<AnyView>] = []
    private var configuredAgentChips: [CodexTranscriptAgentChipRender] = []
    private var agentPreviewPopover: NSPopover?
    private var agentPreviewCloseTask: DispatchWorkItem?
    private var pointerIsInsideAgentPreview = false
    private let diffTabContainer = NSView()
    private var diffTabButtons: [NSButton] = []
    private let diffSelectedUnderline = NSView()
    private var glassBackgroundView: NSHostingView<AnyView>?
    private let approvalAllowButton = NSButton(title: "Allow", target: nil, action: nil)
    private let approvalDenyButton = NSButton(title: "Deny", target: nil, action: nil)
    private let footerTimestampLabel = NSTextField(labelWithString: "")
    private let footerCopyItemButton = NSButton()
    private let footerCopyTurnButton = NSButton()
    private let footerContextButton = NSButton()
    private let backgroundView = NSView()
    private var hostedView: NSView?
    private var item: CodexTranscriptRenderItem?
    private var appKitTheme: CodexTranscriptAppKitTheme?
    private var swiftUITheme = CodexAgentTheme.officialDark
    private var contentHorizontalOffset: CGFloat = 0
    private var performAction: ((CodexTranscriptRenderAction) -> Void)?
    private var copy: ((String) -> Void)?
    private var editUserMessage: ((String) -> Void)?
    private var forkChat: (() -> Void)?
    private var selectionChanged: ((CodexTranscriptRenderItemID, Bool) -> Void)?
    private var preferredHeightChanged: ((CodexTranscriptRenderItemID, Int, CGFloat) -> Void)?
    private var lastReportedPreferredHeight: CGFloat?
    private var isHovered = false
    private var copyConfirmationTokens: [ObjectIdentifier: UUID] = [:]

    var selectableTextViewForTesting: NSTextView { selectableTextView }
    var hasHostedViewForTesting: Bool { hostedView != nil }
    var footerCopyTurnIsVisibleForTesting: Bool { !footerCopyTurnButton.isHidden }
    var footerCopyItemTitleForTesting: String { footerCopyItemButton.title }
    var footerCopyItemToolTipForTesting: String? { footerCopyItemButton.toolTip }
    var contentFrameForTesting: NSRect { backgroundView.frame }
    var codeHeaderIsVisibleForTesting: Bool { !codeHeaderView.isHidden }
    var codeLanguageForTesting: String { codeLanguageLabel.stringValue }
    var copyButtonAccessibilityDescriptionForTesting: String? { copyButton.image?.accessibilityDescription }
    var footerCopyTurnAccessibilityDescriptionForTesting: String? {
        footerCopyTurnButton.image?.accessibilityDescription
    }
    var chipLabelForTesting: String { chipLabel.stringValue }
    var chipIconDescriptionForTesting: String? { chipIconView.image?.accessibilityDescription }
    var chipIsActionableForTesting: Bool { !actionButton.isHidden && actionButton.isEnabled }
    var approvalButtonsVisibleForTesting: Bool { !approvalAllowButton.isHidden && !approvalDenyButton.isHidden }
    var textViewportHeightForTesting: CGFloat { textScrollView.contentSize.height }
    var textDocumentHeightForTesting: CGFloat { selectableTextView.frame.height }
    var hasVerticalScrollerForTesting: Bool { textScrollView.hasVerticalScroller }
    var agentChipCountForTesting: Int { agentChipHosts.count }
    var agentChipTitlesForTesting: [String] {
        configuredAgentChips.map { "\($0.label) · \(Self.agentStatusTitle($0.status).lowercased())" }
    }
    var agentPillsUseGlassForTesting: Bool { !agentChipHosts.isEmpty }
    var workRowStatusForTesting: String { chipStatusLabel.stringValue }
    var workRowBackgroundIsVisibleForTesting: Bool {
        guard let color = chipBackground.layer?.backgroundColor else { return false }
        return NSColor(cgColor: color)?.alphaComponent ?? 0 > 0.01
    }
    var glassPanelIsVisibleForTesting: Bool { glassBackgroundView != nil }
    var diffTabCountForTesting: Int { diffTabButtons.count }
    var workHeaderHasAlignedDisclosureForTesting: Bool {
        guard actionButton.image != nil,
              let imageRect = (actionButton.cell as? NSButtonCell)?.imageRect(forBounds: actionButton.bounds)
        else { return false }
        return abs(imageRect.midY - actionButton.bounds.midY) <= 1
    }
    var textUsedHeightForTesting: CGFloat {
        guard let layoutManager = selectableTextView.layoutManager,
              let textContainer = selectableTextView.textContainer else { return 0 }
        layoutManager.ensureLayout(for: textContainer)
        return layoutManager.usedRect(for: textContainer).height
    }

    func copyItemForTesting() { copyItem(copyButton) }
    func copyTurnForTesting() { copyTurn(footerCopyTurnButton) }
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

    override func loadView() {
        let hoverView = CodexTranscriptHoverView()
        hoverView.onHoverChange = { [weak self] hovered in self?.setHovered(hovered) }
        view = hoverView
        view.wantsLayer = true
        backgroundView.wantsLayer = true
        view.addSubview(backgroundView)

        codeHeaderView.wantsLayer = true
        codeHeaderView.isHidden = true
        view.addSubview(codeHeaderView)

        codeLanguageLabel.isSelectable = false
        codeLanguageLabel.drawsBackground = false
        codeLanguageLabel.isBordered = false
        codeHeaderView.addSubview(codeLanguageLabel)

        chipBackground.wantsLayer = true
        chipBackground.isHidden = true
        view.addSubview(chipBackground)
        chipBackground.addSubview(chipIconView)
        chipBackground.addSubview(chipLabel)
        chipBackground.addSubview(chipDurationLabel)
        chipBackground.addSubview(chipStatusLabel)
        chipBackground.addSubview(chipDisclosureView)

        agentChipContainer.isHidden = true
        view.addSubview(agentChipContainer)

        diffTabContainer.wantsLayer = true
        diffTabContainer.isHidden = true
        diffSelectedUnderline.wantsLayer = true
        diffTabContainer.addSubview(diffSelectedUnderline)
        view.addSubview(diffTabContainer)

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

        selectableTextView.delegate = self
        selectableTextView.onSelectionStateChange = { [weak self] (selecting: Bool) in
            guard let self, let id = self.item?.id else { return }
            self.selectionChanged?(id, selecting)
        }
        textScrollView.documentView = selectableTextView
        textScrollView.drawsBackground = false
        textScrollView.borderType = .noBorder
        textScrollView.hasVerticalScroller = false
        textScrollView.autohidesScrollers = true
        view.addSubview(textScrollView)

        actionButton.isBordered = false
        actionButton.bezelStyle = .inline
        actionButton.alignment = .left
        actionButton.lineBreakMode = .byTruncatingMiddle
        actionButton.target = self
        actionButton.action = #selector(invokePrimaryAction)
        view.addSubview(actionButton)

        copyButton.isBordered = false
        copyButton.bezelStyle = .inline
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        copyButton.imagePosition = .imageOnly
        copyButton.target = self
        copyButton.action = #selector(copyItem(_:))
        copyButton.toolTip = "Copy"
        copyButton.setAccessibilityLabel("Copy")
        view.addSubview(copyButton)

        footerTimestampLabel.isSelectable = false
        footerTimestampLabel.drawsBackground = false
        footerTimestampLabel.isBordered = false
        view.addSubview(footerTimestampLabel)

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
        selectableTextView.string = ""
        selectableTextView.isSelectable = false
        textScrollView.isHidden = true
        actionButton.isHidden = true
        actionButton.image = nil
        copyButton.isHidden = true
        codeHeaderView.isHidden = true
        chipBackground.isHidden = true
        clearAgentChips()
        chipBackground.layer?.borderWidth = 0
        chipLabel.stopShimmer()
        chipDurationLabel.stringValue = ""
        chipStatusLabel.stringValue = ""
        chipDisclosureView.image = nil
        approvalAllowButton.isHidden = true
        approvalDenyButton.isHidden = true
        footerTimestampLabel.isHidden = true
        footerCopyItemButton.isHidden = true
        footerCopyTurnButton.isHidden = true
        footerContextButton.isHidden = true
        backgroundView.isHidden = true
        resetCopyConfirmation(copyButton, imageName: "doc.on.doc", accessibilityDescription: "Copy")
        resetCopyConfirmation(footerCopyItemButton, imageName: "doc.on.doc", accessibilityDescription: "Copy answer")
        resetCopyConfirmation(footerCopyTurnButton, imageName: "doc.on.doc.fill", accessibilityDescription: "Copy turn")
        isHovered = false
        (view as? CodexTranscriptHoverView)?.usesPointingHand = false
        view.menu = nil
        selectableTextView.menu = nil
    }

    func configure(
        item: CodexTranscriptRenderItem,
        appKitTheme: CodexTranscriptAppKitTheme,
        swiftUITheme: CodexAgentTheme,
        contentHorizontalOffset: CGFloat,
        productToolRenderer: CodexProductToolRendererV2?,
        performAction: @escaping (CodexTranscriptRenderAction) -> Void,
        copy: @escaping (String) -> Void,
        editUserMessage: @escaping (String) -> Void,
        forkChat: (() -> Void)?,
        selectionChanged: @escaping (CodexTranscriptRenderItemID, Bool) -> Void,
        preferredHeightChanged: @escaping (CodexTranscriptRenderItemID, Int, CGFloat) -> Void = { _, _, _ in }
    ) {
        let preservesIdentity = self.item?.id == item.id
        let selectionToRestore = preservesIdentity && item.allowsTextSelection
            ? selectableTextView.selectedRange()
            : NSRange(location: 0, length: 0)
        if !preservesIdentity { lastReportedPreferredHeight = nil }
        self.item = item
        self.appKitTheme = appKitTheme
        self.swiftUITheme = swiftUITheme
        self.contentHorizontalOffset = contentHorizontalOffset
        self.performAction = performAction
        self.copy = copy
        self.editUserMessage = editUserMessage
        self.forkChat = forkChat
        self.selectionChanged = selectionChanged
        self.preferredHeightChanged = preferredHeightChanged
        hostedView?.removeFromSuperview()
        hostedView = nil
        clearGlassBackground()
        clearDiffTabs()
        closeAgentPreview()
        backgroundView.isHidden = true
        textScrollView.isHidden = true
        actionButton.isHidden = true
        actionButton.image = nil
        copyButton.isHidden = true
        codeHeaderView.isHidden = true
        chipBackground.isHidden = true
        clearAgentChips()
        chipBackground.layer?.borderWidth = 0
        chipLabel.stopShimmer()
        chipDurationLabel.stringValue = ""
        chipStatusLabel.stringValue = ""
        chipDisclosureView.image = nil
        approvalAllowButton.isHidden = true
        approvalDenyButton.isHidden = true
        (view as? CodexTranscriptHoverView)?.usesPointingHand = false
        footerTimestampLabel.isHidden = true
        footerCopyItemButton.isHidden = true
        footerCopyTurnButton.isHidden = true
        footerContextButton.isHidden = true
        if !item.allowsTextSelection, selectableTextView.selectedRange().length > 0 {
            selectionChanged(item.id, false)
        }
        selectableTextView.isSelectable = item.allowsTextSelection

        if let footer = item.footer {
            configureFooter(footer, item: item, theme: appKitTheme)
        } else if let approval = item.approval {
            configureApproval(approval, item: item, theme: appKitTheme)
        } else if let directive = item.directive {
            configureDirective(directive, item: item, theme: appKitTheme, preserving: selectionToRestore)
        } else if let diffPanel = item.diffPanel {
            configureDiffPanel(
                diffPanel,
                item: item,
                theme: appKitTheme,
                swiftUITheme: swiftUITheme,
                preserving: selectionToRestore
            )
        } else if let code = item.code {
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
            textScrollView.isHidden = false
            textScrollView.hasHorizontalScroller = false
            selectableTextView.isHorizontallyResizable = false
            selectableTextView.textContainer?.widthTracksTextView = true
            selectableTextView.configureLinkAppearance(
                theme: appKitTheme,
                automaticDetection: item.textRole == .expandedOutput
            )
            selectableTextView.bind(
                preparedText.attributedString,
                accessibilityLabel: item.accessibilityLabel,
                preserving: selectionToRestore
            )
            if item.textRole == .user || item.textRole == .expandedOutput {
                backgroundView.isHidden = false
            }
            copyButton.isHidden = item.textRole != .expandedOutput
            if item.isScrollableOutput {
                backgroundView.isHidden = true
                installGlassBackground(theme: swiftUITheme)
            }
        } else if !item.agentChips.isEmpty {
            configureAgentChips(item.agentChips, theme: appKitTheme, swiftUITheme: swiftUITheme)
        } else if let header = item.workHeader {
            actionButton.isHidden = false
            actionButton.font = appKitTheme.captionFont
            actionButton.contentTintColor = appKitTheme.textTertiary
            actionButton.title = Self.workHeaderTitle(header, at: Date())
            actionButton.image = Self.workHeaderDisclosureImage(header)
            actionButton.imagePosition = .imageTrailing
            actionButton.imageScaling = .scaleProportionallyDown
            actionButton.isEnabled = item.action != nil
            actionButton.setAccessibilityLabel(item.accessibilityLabel)
        } else if let row = item.workRow {
            chipBackground.isHidden = false
            chipBackground.layer?.cornerRadius = 0
            chipBackground.layer?.backgroundColor = NSColor.clear.cgColor
            chipBackground.layer?.borderWidth = 0
            chipIconView.image = NSImage(
                systemSymbolName: Self.chipIconName(row),
                accessibilityDescription: Self.chipIconAccessibilityDescription(row)
            )
            chipIconView.contentTintColor = Self.statusColor(row.status, theme: appKitTheme)
            chipLabel.stringValue = row.label
            chipLabel.font = appKitTheme.captionFont
            chipLabel.textColor = appKitTheme.textTertiary
            if row.status == .inProgress { chipLabel.startShimmer() }
            chipDurationLabel.stringValue = row.durationMs.map(CodexWorkBlockViewV2.duration) ?? ""
            chipDurationLabel.font = appKitTheme.microFont
            chipDurationLabel.textColor = appKitTheme.textTertiary
            chipStatusLabel.stringValue = Self.workStatusTitle(row.status)
            chipStatusLabel.font = appKitTheme.captionFont
            chipStatusLabel.textColor = Self.statusColor(row.status, theme: appKitTheme)
            chipDisclosureView.image = Self.chipDisclosureImage(row)
            chipDisclosureView.contentTintColor = appKitTheme.textTertiary
            actionButton.isHidden = !row.isActionable
            actionButton.isEnabled = row.isActionable
            actionButton.title = ""
            actionButton.setAccessibilityLabel(item.accessibilityLabel)
            (view as? CodexTranscriptHoverView)?.usesPointingHand = row.isActionable
        } else if let productTool = item.productTool {
            if let rendered = productToolRenderer?.render(productTool) {
                let hosting = NSHostingView(rootView: AnyView(rendered.codexAgentTheme(swiftUITheme)))
                hosting.setAccessibilityLabel(item.accessibilityLabel)
                hostedView = hosting
                view.addSubview(hosting)
            } else {
                actionButton.isHidden = false
                actionButton.isEnabled = false
                actionButton.font = appKitTheme.captionFont
                actionButton.contentTintColor = appKitTheme.textSecondary
                actionButton.title = codexStatusGlyphV2(productTool.status) + " "
                    + [productTool.namespace, productTool.tool].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
                actionButton.setAccessibilityLabel(item.accessibilityLabel)
                backgroundView.isHidden = false
            }
        }

        configureContextMenu()
        updateFooterChromeVisibility()
        view.needsLayout = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let item, let theme = appKitTheme else { return }
        let metrics = CodexTranscriptColumnMetrics(viewportWidth: item.viewportWidth)
        let outerWidth = metrics.outerWidth(theme)
        let centerX = item.viewportWidth / 2 + contentHorizontalOffset
        let outerMinX = centerX - outerWidth / 2
        let contentWidth = min(
            item.intrinsicContentWidth ?? item.maxContentWidth,
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
            var textFrame = contentFrame.insetBy(dx: insetX, dy: insetY)
            if item.textRole == .expandedOutput { textFrame.size.width = max(40, textFrame.width - 30) }
            layoutSelectableText(
                in: textFrame,
                allowsHorizontalScrolling: false,
                allowsVerticalScrolling: item.isScrollableOutput
            )
            copyButton.frame = NSRect(x: contentFrame.maxX - 30, y: contentFrame.maxY - 28, width: 26, height: 24)
        } else if !item.agentChips.isEmpty {
            layoutAgentChips(item.agentChips, in: contentFrame, theme: theme)
        } else if let row = item.workRow {
            chipBackground.frame = contentFrame
            let rowMidY = contentFrame.height / 2
            let disclosureWidth: CGFloat = row.isActionable ? 14 : 0
            chipDisclosureView.frame = NSRect(
                x: 0,
                y: rowMidY - 7,
                width: disclosureWidth,
                height: 14
            )
            let iconSize: CGFloat = 15
            let iconX = disclosureWidth > 0 ? disclosureWidth + 6 : 0
            chipIconView.frame = NSRect(x: iconX, y: rowMidY - iconSize / 2, width: iconSize, height: iconSize)

            chipStatusLabel.sizeToFit()
            chipDurationLabel.sizeToFit()
            let statusWidth = chipStatusLabel.frame.width
            chipDurationLabel.sizeToFit()
            let durationWidth = chipDurationLabel.stringValue.isEmpty ? 0 : chipDurationLabel.frame.width
            let labelX = iconX + iconSize + 8
            let trailingWidth = statusWidth + (durationWidth > 0 ? durationWidth + 10 : 0)
            let naturalLabelWidth = ceil((chipLabel.stringValue as NSString).size(
                withAttributes: [.font: chipLabel.font ?? theme.captionFont]
            ).width)
            let labelWidth = min(
                naturalLabelWidth,
                max(20, contentFrame.width - labelX - trailingWidth - 20)
            )
            chipLabel.frame = NSRect(x: labelX, y: rowMidY - 10, width: labelWidth, height: 20)
            chipDurationLabel.frame = NSRect(
                x: chipLabel.frame.maxX + (durationWidth > 0 ? 10 : 0),
                y: rowMidY - 9,
                width: durationWidth,
                height: 18
            )
            chipStatusLabel.frame = NSRect(
                x: (durationWidth > 0 ? chipDurationLabel.frame.maxX : chipLabel.frame.maxX) + 10,
                y: rowMidY - 10,
                width: statusWidth,
                height: 20
            )
            actionButton.frame = contentFrame
        } else {
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
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: toolTip)
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
        chipIconView.image = NSImage(systemSymbolName: "hand.raised", accessibilityDescription: "Approval needed")
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
        chipIconView.image = NSImage(
            systemSymbolName: Self.directiveIconName(directive.kind),
            accessibilityDescription: item.accessibilityLabel
        )
        chipIconView.contentTintColor = Self.directiveTint(directive.kind, theme: theme)
        chipLabel.stringValue = Self.directiveLabel(directive.kind)
        chipLabel.font = theme.captionFont
        chipLabel.textColor = theme.textSecondary
        chipDurationLabel.font = theme.microFont
        chipDurationLabel.textColor = theme.textTertiary
        chipDisclosureView.contentTintColor = theme.textTertiary
        chipDisclosureView.image = item.action == nil ? nil : NSImage(
            systemSymbolName: "arrow.up.right", accessibilityDescription: "Open"
        )
        actionButton.isHidden = item.action == nil
        actionButton.isEnabled = item.action != nil
        actionButton.title = ""
        actionButton.setAccessibilityLabel(item.accessibilityLabel)
        actionButton.toolTip = Self.directiveToolTip(directive.kind, raw: directive.raw)
        (view as? CodexTranscriptHoverView)?.usesPointingHand = item.action != nil

        if case .codeComment(_, _, let file, let start, _, let priority) = directive.kind {
            chipDurationLabel.stringValue = priority.map { "P\($0)" } ?? ""
            chipDisclosureView.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Open file")
            if let prepared = item.preparedText?.attributedString {
                textScrollView.isHidden = false
                textScrollView.hasHorizontalScroller = false
                selectableTextView.isHorizontallyResizable = false
                selectableTextView.textContainer?.widthTracksTextView = true
                selectableTextView.configureLinkAppearance(theme: theme, automaticDetection: false)
                selectableTextView.bind(prepared, accessibilityLabel: item.accessibilityLabel, preserving: selection)
            }
            actionButton.toolTip = file + (start.map { ":\($0)" } ?? "")
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
        actionButton.frame = contentFrame

        if case .codeComment(_, _, let file, let start, _, _) = directive.kind {
            chipIconView.frame.origin.y = contentFrame.height - 26
            chipLabel.frame = NSRect(x: 32, y: contentFrame.height - 28, width: max(20, contentFrame.width - 100), height: 20)
            chipDurationLabel.frame = NSRect(x: contentFrame.width - badgeWidth - 10, y: contentFrame.height - 28, width: badgeWidth, height: 18)
            layoutSelectableText(
                in: NSRect(x: contentFrame.minX + 12, y: 26, width: contentFrame.width - 24, height: max(20, contentFrame.height - 62)),
                allowsHorizontalScrolling: false
            )
            chipDisclosureView.frame = NSRect(x: 10, y: 5, width: 16, height: 16)
            chipDisclosureView.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Open file")
            actionButton.title = file + (start.map { ":\($0)" } ?? "")
            actionButton.font = appKitTheme?.microFont
            actionButton.contentTintColor = appKitTheme?.textTertiary
            actionButton.alignment = .left
            actionButton.frame = NSRect(x: contentFrame.minX + 30, y: 2, width: contentFrame.width - 40, height: 22)
        }
    }

    private static func directiveLabel(_ kind: CodexTranscriptDirectiveRender.Kind) -> String {
        switch kind {
        case .createdThread(let threadID, let pendingID):
            return "Created thread · " + shortIdentifier(threadID ?? pendingID ?? "pending")
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
        footerTimestampLabel.isHidden = false
        footerTimestampLabel.stringValue = footer.timestamp
        footerTimestampLabel.font = theme.microFont
        footerTimestampLabel.textColor = theme.textTertiary
        footerTimestampLabel.setAccessibilityLabel(item.accessibilityLabel)
        footerCopyItemButton.font = theme.microFont
        footerCopyTurnButton.font = theme.microFont
        footerContextButton.font = theme.microFont
        footerCopyItemButton.contentTintColor = theme.textTertiary
        footerCopyTurnButton.contentTintColor = theme.textTertiary
        footerContextButton.contentTintColor = theme.textTertiary

        switch footer.kind {
        case .user:
            footerContextButton.image = NSImage(
                systemSymbolName: "square.and.pencil",
                accessibilityDescription: "Edit prompt"
            )
            footerContextButton.action = #selector(editUser)
            footerContextButton.toolTip = "Edit prompt"
            footerContextButton.setAccessibilityLabel("Edit prompt")
        case .finalAnswer:
            footerContextButton.image = NSImage(
                systemSymbolName: "arrow.triangle.branch",
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
        updateFooterChromeVisibility()
        updateChipAppearance()
        view.needsLayout = true
    }

    private func updateChipAppearance() {
        guard item?.workRow != nil else { return }
        chipBackground.layer?.backgroundColor = NSColor.clear.cgColor
        chipBackground.layer?.borderWidth = 0
    }

    private func updateFooterChromeVisibility() {
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
        let visibleButtons = [footerCopyItemButton, footerCopyTurnButton, footerContextButton]
            .filter { !$0.isHidden }
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
        theme: CodexTranscriptAppKitTheme,
        swiftUITheme: CodexAgentTheme
    ) {
        clearAgentChips()
        configuredAgentChips = chips
        agentChipContainer.isHidden = false
        for (index, chip) in chips.enumerated() {
            let pill = CodexTranscriptAgentPill(
                chip: chip,
                onHover: { [weak self] hovered in
                    self?.setAgentPreviewHover(hovered, index: index)
                },
                onOpen: { [weak self] in
                    guard let threadID = chip.threadID else { return }
                    self?.performAction?(.openSubagent(threadID: threadID))
                }
            )
            let host = NSHostingView(rootView: AnyView(pill.codexAgentTheme(swiftUITheme)))
            host.setAccessibilityLabel("\(chip.label), \(Self.agentStatusTitle(chip.status))")
            agentChipContainer.addSubview(host)
            agentChipHosts.append(host)
        }
    }

    private func layoutAgentChips(
        _ chips: [CodexTranscriptAgentChipRender],
        in contentFrame: NSRect,
        theme: CodexTranscriptAppKitTheme
    ) {
        agentChipContainer.frame = contentFrame
        let height: CGFloat = 26
        let gap: CGFloat = 6
        var x: CGFloat = 0
        var y = contentFrame.height - height
        for (chip, host) in zip(chips, agentChipHosts) {
            let title = "\(chip.label) · \(Self.agentStatusTitle(chip.status).lowercased())"
            let labelWidth = ceil((title as NSString).size(withAttributes: [.font: theme.captionFont]).width)
            let width = min(contentFrame.width, max(74, labelWidth + 28))
            if x > 0, x + width > contentFrame.width {
                x = 0
                y -= height + gap
            }
            host.frame = NSRect(x: x, y: max(0, y), width: width, height: height)
            x += width + gap
        }
    }

    private func clearAgentChips() {
        agentChipHosts.forEach { $0.removeFromSuperview() }
        agentChipHosts.removeAll(keepingCapacity: true)
        configuredAgentChips.removeAll(keepingCapacity: true)
        agentChipContainer.isHidden = true
    }

    private static func agentStatusTitle(_ status: CodexAgentDisplayStatusV2) -> String {
        switch status {
        case .starting: "Starting"
        case .working: "Working"
        case .done: "Done"
        case .failed: "Failed"
        case .closed: "Closed"
        }
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
        popover.contentSize = NSSize(width: 300, height: hasDetails ? 142 : 92)
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
        guard let header = item?.workHeader else { return }
        actionButton.title = Self.workHeaderTitle(header, at: date)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let id = item?.id else { return }
        selectionChanged?(id, selectableTextView.selectedRange().length > 0)
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
        guard let text = item?.copyText else { return }
        copy?(text)
        if let button = sender as? NSButton { flashCopyConfirmation(button) }
    }

    @objc private func copySelectionOrItem() {
        if selectableTextView.selectedRange().length > 0 {
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
              let text = item.copyText else { return }
        editUserMessage?(text)
    }

    @objc private func invokeForkChat() {
        forkChat?()
    }

    private func configureContextMenu() {
        guard let item else { return }
        let menu = NSMenu()
        if item.copyText != nil {
            let title: String = if item.code != nil { "Copy code" }
                else if item.textRole == .expandedOutput { "Copy output" }
                else if item.textRole == .finalAnswer || item.footer?.kind == .finalAnswer { "Copy final answer" }
                else { "Copy" }
            let action = item.code != nil || item.textRole == .expandedOutput || item.footer != nil
                ? #selector(copyItem(_:))
                : #selector(copySelectionOrItem)
            menu.addItem(withTitle: title, action: action, keyEquivalent: "")
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
        for menuItem in menu.items { menuItem.target = self }
        view.menu = menu
        selectableTextView.menu = menu
    }

    private func flashCopyConfirmation(_ button: NSButton) {
        let key = ObjectIdentifier(button)
        let token = UUID()
        let originalImage = button.image
        let originalTint = button.contentTintColor
        copyConfirmationTokens[key] = token
        button.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
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
        button.image = NSImage(
            systemSymbolName: imageName,
            accessibilityDescription: accessibilityDescription
        )
        button.contentTintColor = appKitTheme?.textTertiary
    }

    private static func workHeaderTitle(_ header: CodexTranscriptWorkHeaderRender, at date: Date) -> String {
        switch header.state {
        case .working(let startedAt, let showsDuration):
            return showsDuration ? "Working for \(max(0, Int(date.timeIntervalSince(startedAt))))s" : "Thinking"
        case .done(let durationMs, let isExpanded):
            _ = isExpanded
            return CodexWorkBlockViewV2.completedLabel(durationMs)
        case .failed(let message):
            return message.isEmpty ? "Work failed" : message
        }
    }

    private static func workHeaderDisclosureImage(_ header: CodexTranscriptWorkHeaderRender) -> NSImage? {
        guard case .done(_, let isExpanded) = header.state else { return nil }
        return NSImage(
            systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
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
        if row.status == .failed { return "exclamationmark.triangle" }
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
        }
    }

    private static func chipDisclosureImage(_ row: CodexTranscriptWorkRowRender) -> NSImage? {
        guard row.isActionable else { return nil }
        let name = row.isSubagentLink ? "arrow.up.right" : (row.isExpanded ? "chevron.down" : "chevron.right")
        return NSImage(systemSymbolName: name, accessibilityDescription: row.isSubagentLink ? "Open agent" : "Show details")
    }

    private static func statusColor(
        _ status: CodexWorkItemStatusV2,
        theme: CodexTranscriptAppKitTheme
    ) -> NSColor {
        switch status {
        case .inProgress: theme.running
        case .completed: theme.success
        case .failed: theme.danger
        }
    }

    private static func workStatusTitle(_ status: CodexWorkItemStatusV2) -> String {
        switch status {
        case .inProgress: "running"
        case .completed: "finished"
        case .failed: "failed"
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
            .codexGlass(
                RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous),
                tint: theme.colors.surface.opacity(0.34)
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                    .stroke(theme.colors.borderStrong.opacity(0.58), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

private struct CodexTranscriptAgentPill: View {
    @Environment(\.codexAgentTheme) private var theme

    let chip: CodexTranscriptAgentChipRender
    let onHover: (Bool) -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(chip.label)
                .foregroundStyle(theme.colors.textPrimary)
            Text("· \(statusTitle.lowercased())")
                .foregroundStyle(theme.colors.textSecondary)
        }
        .font(theme.fonts.caption)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .contentShape(Capsule())
        .codexGlass(Capsule(), tint: statusColor.opacity(0.055), interactive: chip.threadID != nil)
        .overlay {
            Capsule().stroke(theme.colors.borderStrong.opacity(0.55), lineWidth: 1)
        }
        .onTapGesture(perform: onOpen)
        .onHover(perform: onHover)
        .help("\(chip.label) — \(statusTitle)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(chip.label), \(statusTitle)")
        .accessibilityAddTraits(chip.threadID == nil ? [] : .isButton)
    }

    private var statusTitle: String {
        switch chip.status {
        case .starting: "Starting"
        case .working: "Working"
        case .done: "Done"
        case .failed: "Failed"
        case .closed: "Closed"
        }
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

private struct CodexTranscriptAgentHoverPreview: View {
    @Environment(\.codexAgentTheme) private var theme

    let chip: CodexTranscriptAgentChipRender
    let onHover: (Bool) -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(chip.label).font(theme.fonts.label)
                Spacer(minLength: 8)
                Text(statusTitle).font(theme.fonts.caption).foregroundStyle(statusColor)
            }

            if let task = chip.taskSummary {
                previewRow("Task", task)
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
        .codexGlass(
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous),
            tint: theme.colors.surface.opacity(0.38)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.borderStrong.opacity(0.6), lineWidth: 1)
        }
        .onHover(perform: onHover)
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
        switch chip.status {
        case .starting: "Starting"
        case .working: "Working"
        case .done: "Done"
        case .failed: "Failed"
        case .closed: "Closed"
        }
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
