import AppKit
import SwiftUI

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

    var selectableTextViewForTesting: NSTextView { selectableTextView }
    var hasHostedViewForTesting: Bool { hostedView != nil }

    func copyItemForTesting() { copyItem() }
    func copyTurnForTesting() { copyTurn() }
    func invokePrimaryActionForTesting() { invokePrimaryAction() }
    func editUserForTesting() { editUser() }
    func forkChatForTesting() { invokeForkChat() }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        backgroundView.wantsLayer = true
        view.addSubview(backgroundView)

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
        copyButton.action = #selector(copyItem)
        copyButton.toolTip = "Copy"
        copyButton.setAccessibilityLabel("Copy")
        view.addSubview(copyButton)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let id = item?.id { selectionChanged?(id, false) }
        item = nil
        hostedView?.removeFromSuperview()
        hostedView = nil
        selectableTextView.string = ""
        textScrollView.isHidden = true
        actionButton.isHidden = true
        copyButton.isHidden = true
        backgroundView.isHidden = true
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
        selectionChanged: @escaping (CodexTranscriptRenderItemID, Bool) -> Void
    ) {
        let selectionToRestore = self.item?.id == item.id
            ? selectableTextView.selectedRange()
            : NSRange(location: 0, length: 0)
        self.item = item
        self.appKitTheme = appKitTheme
        self.contentHorizontalOffset = contentHorizontalOffset
        self.performAction = performAction
        self.copy = copy
        self.editUserMessage = editUserMessage
        self.forkChat = forkChat
        self.selectionChanged = selectionChanged
        hostedView?.removeFromSuperview()
        hostedView = nil
        backgroundView.isHidden = true
        textScrollView.isHidden = true
        actionButton.isHidden = true
        copyButton.isHidden = true

        if let preparedText = item.preparedText {
            textScrollView.isHidden = false
            textScrollView.hasHorizontalScroller = false
            selectableTextView.isHorizontallyResizable = false
            selectableTextView.textContainer?.widthTracksTextView = true
            selectableTextView.bind(
                preparedText.attributedString,
                accessibilityLabel: item.accessibilityLabel,
                preserving: selectionToRestore
            )
            if item.textRole == .user || item.textRole == .expandedOutput {
                backgroundView.isHidden = false
            }
            copyButton.isHidden = item.textRole != .expandedOutput
        } else if let code = item.code {
            textScrollView.isHidden = false
            textScrollView.hasHorizontalScroller = true
            selectableTextView.isHorizontallyResizable = true
            selectableTextView.textContainer?.widthTracksTextView = false
            selectableTextView.bind(
                NSAttributedString(string: code.code, attributes: [
                    .font: appKitTheme.codeFont,
                    .foregroundColor: appKitTheme.codeText,
                    .paragraphStyle: Self.paragraphStyle(appKitTheme)
                ]),
                accessibilityLabel: item.accessibilityLabel,
                preserving: selectionToRestore
            )
            backgroundView.isHidden = false
            actionButton.isHidden = false
            actionButton.title = code.language?.isEmpty == false ? code.language! : "code"
            actionButton.font = appKitTheme.captionFont
            actionButton.contentTintColor = appKitTheme.codeFaint
            actionButton.isEnabled = false
            copyButton.isHidden = false
        } else if let header = item.workHeader {
            actionButton.isHidden = false
            actionButton.font = appKitTheme.captionFont
            actionButton.contentTintColor = appKitTheme.textTertiary
            actionButton.title = Self.workHeaderTitle(header, at: Date())
            actionButton.isEnabled = item.action != nil
            actionButton.setAccessibilityLabel(item.accessibilityLabel)
        } else if let row = item.workRow {
            actionButton.isHidden = false
            actionButton.font = appKitTheme.captionFont
            actionButton.attributedTitle = Self.workRowTitle(row, theme: appKitTheme)
            actionButton.isEnabled = true
            actionButton.setAccessibilityLabel(item.accessibilityLabel)
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
        view.needsLayout = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let item, let theme = appKitTheme else { return }
        let outerWidth = max(200, min(view.bounds.width - 48, theme.transcriptOuterMaxWidth))
        let centerX = view.bounds.midX + contentHorizontalOffset
        let outerMinX = centerX - outerWidth / 2
        let contentWidth = min(item.maxContentWidth, outerWidth - item.indentation)
        let contentX = item.isTrailingAligned
            ? outerMinX + outerWidth - contentWidth
            : outerMinX + item.indentation
        let contentFrame = NSRect(x: contentX, y: 0, width: contentWidth, height: view.bounds.height)

        backgroundView.frame = contentFrame
        backgroundView.layer?.cornerRadius = item.textRole == .user ? theme.bubbleRadius : theme.cardRadius
        backgroundView.layer?.backgroundColor = Self.backgroundColor(item: item, theme: theme).cgColor
        backgroundView.layer?.borderColor = Self.borderColor(item: item, theme: theme).cgColor
        backgroundView.layer?.borderWidth = backgroundView.isHidden ? 0 : 1

        if item.code != nil {
            actionButton.frame = NSRect(x: contentX + 12, y: view.bounds.height - 35, width: contentWidth - 58, height: 28)
            copyButton.frame = NSRect(x: contentFrame.maxX - 36, y: view.bounds.height - 34, width: 28, height: 26)
            layoutSelectableText(
                in: NSRect(x: contentX + 12, y: 10, width: contentWidth - 24, height: max(20, view.bounds.height - 50)),
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
        } else {
            actionButton.frame = contentFrame
        }
        hostedView?.frame = contentFrame
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

    @objc private func copyItem() {
        guard let text = item?.copyText else { return }
        copy?(text)
    }

    @objc private func copySelectionOrItem() {
        if selectableTextView.selectedRange().length > 0 {
            selectableTextView.copy(nil)
        } else {
            copyItem()
        }
    }

    @objc private func copyTurn() {
        guard let text = item?.copyTurnText else { return }
        copy?(text)
    }

    @objc private func editUser() {
        guard item?.textRole == .user, let text = item?.copyText else { return }
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
                else if item.textRole == .finalAnswer { "Copy final answer" }
                else { "Copy" }
            let action = item.code != nil || item.textRole == .expandedOutput
                ? #selector(copyItem)
                : #selector(copySelectionOrItem)
            menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        }
        menu.addItem(withTitle: "Copy turn", action: #selector(copyTurn), keyEquivalent: "")
        if item.textRole == .user {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Edit message", action: #selector(editUser), keyEquivalent: "")
        }
        if item.textRole == .finalAnswer, forkChat != nil {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Fork chat", action: #selector(invokeForkChat), keyEquivalent: "")
        }
        for menuItem in menu.items { menuItem.target = self }
        view.menu = menu
        selectableTextView.menu = menu
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
