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
    private let chipDisclosureView = NSImageView()
    private let footerTimestampLabel = NSTextField(labelWithString: "")
    private let footerCopyItemButton = NSButton()
    private let footerCopyTurnButton = NSButton()
    private let footerContextButton = NSButton()
    private let backgroundView = NSView()
    private var hostedView: NSView?
    private var item: CodexTranscriptRenderItem?
    private var appKitTheme: CodexTranscriptAppKitTheme?
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

    func copyItemForTesting() { copyItem(copyButton) }
    func copyTurnForTesting() { copyTurn(footerCopyTurnButton) }
    func invokePrimaryActionForTesting() { invokePrimaryAction() }
    func editUserForTesting() { editUser() }
    func forkChatForTesting() { invokeForkChat() }
    func setHoveredForTesting(_ hovered: Bool) { setHovered(hovered) }

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
        chipBackground.addSubview(chipDisclosureView)

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
        selectableTextView.string = ""
        selectableTextView.isSelectable = false
        textScrollView.isHidden = true
        actionButton.isHidden = true
        copyButton.isHidden = true
        codeHeaderView.isHidden = true
        chipBackground.isHidden = true
        chipLabel.stopShimmer()
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
        self.contentHorizontalOffset = contentHorizontalOffset
        self.performAction = performAction
        self.copy = copy
        self.editUserMessage = editUserMessage
        self.forkChat = forkChat
        self.selectionChanged = selectionChanged
        self.preferredHeightChanged = preferredHeightChanged
        hostedView?.removeFromSuperview()
        hostedView = nil
        backgroundView.isHidden = true
        textScrollView.isHidden = true
        actionButton.isHidden = true
        copyButton.isHidden = true
        codeHeaderView.isHidden = true
        chipBackground.isHidden = true
        chipLabel.stopShimmer()
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
        } else if let header = item.workHeader {
            actionButton.isHidden = false
            actionButton.font = appKitTheme.captionFont
            actionButton.contentTintColor = appKitTheme.textTertiary
            actionButton.title = Self.workHeaderTitle(header, at: Date())
            actionButton.isEnabled = item.action != nil
            actionButton.setAccessibilityLabel(item.accessibilityLabel)
        } else if let row = item.workRow {
            chipBackground.isHidden = false
            chipBackground.layer?.cornerRadius = appKitTheme.cardRadius
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
            chipDisclosureView.image = Self.chipDisclosureImage(row)
            chipDisclosureView.contentTintColor = appKitTheme.textTertiary
            actionButton.isHidden = !row.isActionable
            actionButton.isEnabled = row.isActionable
            actionButton.title = ""
            actionButton.setAccessibilityLabel(item.accessibilityLabel)
            (view as? CodexTranscriptHoverView)?.usesPointingHand = row.isActionable
            updateChipAppearance()
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
        let contentFrame = NSRect(x: contentX, y: 0, width: contentWidth, height: view.bounds.height)

        backgroundView.frame = contentFrame
        backgroundView.layer?.cornerRadius = item.textRole == .user ? theme.bubbleRadius : theme.cardRadius
        backgroundView.layer?.backgroundColor = Self.backgroundColor(item: item, theme: theme).cgColor
        backgroundView.layer?.borderColor = Self.borderColor(item: item, theme: theme).cgColor
        backgroundView.layer?.borderWidth = backgroundView.isHidden ? 0 : 1

        if item.footer != nil {
            layoutFooter(in: contentFrame, trailing: item.isTrailingAligned)
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
                allowsHorizontalScrolling: true
            )
        } else if item.preparedText != nil {
            let insetX: CGFloat = item.textRole == .user ? 14 : (item.textRole == .expandedOutput ? 12 : 0)
            let insetY: CGFloat = item.textRole == .user ? 10 : (item.textRole == .expandedOutput ? 8 : 2)
            var textFrame = contentFrame.insetBy(dx: insetX, dy: insetY)
            if item.textRole == .expandedOutput { textFrame.size.width = max(40, textFrame.width - 30) }
            layoutSelectableText(
                in: textFrame,
                allowsHorizontalScrolling: false
            )
            copyButton.frame = NSRect(x: contentFrame.maxX - 30, y: contentFrame.maxY - 28, width: 26, height: 24)
        } else if let row = item.workRow {
            chipBackground.frame = contentFrame
            let iconSize: CGFloat = 16
            chipIconView.frame = NSRect(x: 8, y: contentFrame.midY - iconSize / 2, width: iconSize, height: iconSize)
            chipDurationLabel.sizeToFit()
            let durationWidth = chipDurationLabel.stringValue.isEmpty ? 0 : chipDurationLabel.frame.width
            let disclosureWidth: CGFloat = row.isActionable ? 16 : 0
            chipDisclosureView.frame = NSRect(
                x: contentFrame.width - 8 - disclosureWidth,
                y: contentFrame.midY - 8,
                width: disclosureWidth,
                height: 16
            )
            chipDurationLabel.frame = NSRect(
                x: chipDisclosureView.frame.minX - (durationWidth > 0 ? durationWidth + 8 : 0),
                y: contentFrame.midY - 9,
                width: durationWidth,
                height: 18
            )
            let labelX: CGFloat = 32
            chipLabel.frame = NSRect(
                x: labelX,
                y: contentFrame.midY - 10,
                width: max(20, chipDurationLabel.frame.minX - labelX - 8),
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
        guard let theme = appKitTheme, let row = item?.workRow else { return }
        let alpha: CGFloat = row.isActionable && isHovered ? 0.9 : 0.45
        chipBackground.layer?.backgroundColor = theme.surfaceSunken.withAlphaComponent(alpha).cgColor
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

    private func layoutSelectableText(in frame: NSRect, allowsHorizontalScrolling: Bool) {
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
        selectableTextView.textContainer?.containerSize = NSSize(
            width: documentWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        selectableTextView.frame = NSRect(
            x: 0,
            y: 0,
            width: documentWidth,
            height: max(20, viewport.height)
        )
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
            return "Worked for \(CodexWorkBlockViewV2.duration(durationMs))  \(isExpanded ? "⌄" : "›")"
        case .failed(let message):
            return message.isEmpty ? "Work failed" : message
        }
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
