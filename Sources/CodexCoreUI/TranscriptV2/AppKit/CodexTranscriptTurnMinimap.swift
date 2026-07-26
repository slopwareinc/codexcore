import AppKit

struct CodexTranscriptTurnMinimapEntry: Equatable {
    var turnID: String
    var targetItemID: CodexTranscriptRenderItemID
    var title: String
    var detail: String
}

enum CodexTranscriptTurnMinimapProjection {
    static func entries(
        presentation: CodexThreadUIPresentation,
        snapshot: CodexTranscriptRenderSnapshot
    ) -> [CodexTranscriptTurnMinimapEntry] {
        var firstItemByTurnID: [String: CodexTranscriptRenderItemID] = [:]
        for itemID in snapshot.orderedItemIDs {
            guard let turnID = snapshot.itemsByID[itemID]?.turnID,
                  firstItemByTurnID[turnID] == nil else { continue }
            firstItemByTurnID[turnID] = itemID
        }
        return presentation.transcript.turns.enumerated().compactMap { index, turn in
            guard let targetItemID = firstItemByTurnID[turn.id] else { return nil }
            return CodexTranscriptTurnMinimapEntry(
                turnID: turn.id,
                targetItemID: targetItemID,
                title: previewText(
                    turn.userMessage?.displayText
                        ?? turn.steeredMessages.first?.displayText
                        ?? "Turn \(index + 1)",
                    limit: 110
                ),
                detail: previewText(
                    turn.finalAnswer?.text
                        ?? turn.liveTail
                        ?? latestAssistantText(in: turn)
                        ?? statusText(turn.status),
                    limit: 520,
                    collapsesWhitespace: false
                )
            )
        }
    }

    private static func latestAssistantText(in turn: CodexTurnV2) -> String? {
        for segment in turn.conversationSegments.reversed() {
            for entry in segment.narrative.reversed() {
                switch entry {
                case .prose(let prose) where !prose.text.isEmpty:
                    return prose.text
                case .notice(let notice) where !notice.message.isEmpty:
                    return notice.message
                case .workGroup(let group) where !group.header.isEmpty:
                    return group.header
                case .productToolCall, .prose, .notice, .workGroup:
                    continue
                }
            }
        }
        return nil
    }

    private static func statusText(_ status: CodexTurnStatusV2) -> String {
        switch status {
        case .working:
            "Working…"
        case .done:
            "Completed"
        case .failed(let message):
            message
        }
    }

    private static func previewText(
        _ text: String,
        limit: Int,
        collapsesWhitespace: Bool = true
    ) -> String {
        let normalized = collapsesWhitespace
            ? text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            : text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

@MainActor
final class CodexTranscriptTurnMinimapView: NSView {
    private var controlsByTurnID: [String: CodexTranscriptTurnMarkerControl] = [:]
    private var entries: [CodexTranscriptTurnMinimapEntry] = []
    private var activeTurnID: String?

    var onSelect: ((CodexTranscriptTurnMinimapEntry) -> Void)?
    var onHover: ((CodexTranscriptTurnMinimapEntry?, NSView?) -> Void)?

    override var isFlipped: Bool { true }

    func configure(
        entries: [CodexTranscriptTurnMinimapEntry],
        activeTurnID: String?,
        theme: CodexTranscriptAppKitTheme
    ) {
        self.entries = entries
        self.activeTurnID = activeTurnID

        let liveTurnIDs = Set(entries.map(\.turnID))
        let staleTurnIDs = controlsByTurnID.keys.filter { !liveTurnIDs.contains($0) }
        for turnID in staleTurnIDs {
            controlsByTurnID.removeValue(forKey: turnID)?.removeFromSuperview()
        }
        for entry in entries {
            let control = controlsByTurnID[entry.turnID] ?? makeControl(for: entry)
            control.entry = entry
            control.isCurrent = entry.turnID == activeTurnID
            control.markerColor = theme.textTertiary
            control.activeColor = theme.textSecondary
            control.setAccessibilityLabel("Jump to turn: \(entry.title)")
            control.setAccessibilityHelp(entry.detail)
            control.setAccessibilityIdentifier("transcript-turn-marker-\(entry.turnID)")
        }
        needsLayout = true
    }

    func setActiveTurnID(_ turnID: String?) {
        guard activeTurnID != turnID else { return }
        if let activeTurnID { controlsByTurnID[activeTurnID]?.isCurrent = false }
        activeTurnID = turnID
        if let turnID { controlsByTurnID[turnID]?.isCurrent = true }
    }

    override func layout() {
        super.layout()
        guard !entries.isEmpty else { return }
        let slotHeight = bounds.height / CGFloat(entries.count)
        for (index, entry) in entries.enumerated() {
            guard let control = controlsByTurnID[entry.turnID] else { continue }
            control.frame = NSRect(
                x: 0,
                y: CGFloat(index) * slotHeight,
                width: bounds.width,
                height: max(1, slotHeight)
            )
            control.lineCenterY = slotHeight / 2
        }
    }

    private func makeControl(
        for entry: CodexTranscriptTurnMinimapEntry
    ) -> CodexTranscriptTurnMarkerControl {
        let control = CodexTranscriptTurnMarkerControl()
        control.entry = entry
        control.target = self
        control.action = #selector(selectMarker(_:))
        control.onHover = { [weak self, weak control] isHovered in
            guard let self, let control else { return }
            self.onHover?(isHovered ? control.entry : nil, isHovered ? control : nil)
        }
        control.setAccessibilityElement(true)
        control.setAccessibilityRole(.button)
        addSubview(control)
        controlsByTurnID[entry.turnID] = control
        return control
    }

    @objc private func selectMarker(_ sender: CodexTranscriptTurnMarkerControl) {
        onSelect?(sender.entry)
    }

    var entriesForTesting: [CodexTranscriptTurnMinimapEntry] { entries }
    var activeTurnIDForTesting: String? { activeTurnID }
    func markerForTesting(turnID: String) -> NSView? { controlsByTurnID[turnID] }
    func preferredHeight(maximum: CGFloat) -> CGFloat {
        min(maximum, CGFloat(entries.count) * 11)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        subviews.first(where: { $0.frame.contains(point) })
    }
}

@MainActor
private final class CodexTranscriptTurnMarkerControl: NSControl {
    var entry = CodexTranscriptTurnMinimapEntry(
        turnID: "",
        targetItemID: .init(rawValue: ""),
        title: "",
        detail: ""
    )
    var markerColor = NSColor.tertiaryLabelColor { didSet { needsDisplay = true } }
    var activeColor = NSColor.secondaryLabelColor { didSet { needsDisplay = true } }
    var isCurrent = false { didSet { needsDisplay = true } }
    var lineCenterY: CGFloat = 0 { didSet { needsDisplay = true } }
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(next)
        trackingArea = next
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let width: CGFloat = isCurrent || isHovered ? 28 : 10
        let line = NSRect(
            x: 0,
            y: lineCenterY - 1,
            width: min(width, bounds.width),
            height: isCurrent ? 2.5 : 2
        )
        (isCurrent || isHovered ? activeColor : markerColor)
            .withAlphaComponent(isCurrent ? 0.95 : isHovered ? 0.78 : 0.42)
            .setFill()
        NSBezierPath(roundedRect: line, xRadius: 1.25, yRadius: 1.25).fill()
    }
}

@MainActor
final class CodexTranscriptTurnPreviewView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var isPointerInside = false
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        detailLabel.maximumNumberOfLines = 6
        detailLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        addSubview(detailLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        entry: CodexTranscriptTurnMinimapEntry,
        theme: CodexTranscriptAppKitTheme
    ) {
        titleLabel.stringValue = entry.title
        titleLabel.font = NSFont.systemFont(
            ofSize: max(12, theme.bodyFont.pointSize - 1),
            weight: .medium
        )
        titleLabel.textColor = theme.textPrimary
        detailLabel.font = theme.captionFont
        detailLabel.textColor = theme.textSecondary
        detailLabel.attributedStringValue =
            CodexTranscriptRenderProjector.prepareMinimapPreviewMarkdown(
                entry.detail,
                theme: theme
            )
        layer?.backgroundColor = theme.surfaceSunken.withAlphaComponent(0.98).cgColor
        layer?.borderColor = theme.border.withAlphaComponent(0.72).cgColor
        setAccessibilityLabel(entry.title)
        setAccessibilityHelp(entry.detail)
    }

    func preferredHeight(for width: CGFloat) -> CGFloat {
        let detailWidth = max(1, width - 24)
        let detailHeight = min(
            102,
            ceil(detailLabel.attributedStringValue.boundingRect(
                with: NSSize(width: detailWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height)
        )
        return max(86, 52 + detailHeight)
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(next)
        trackingArea = next
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        onHoverChanged?(false)
    }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 12, y: bounds.height - 34, width: bounds.width - 24, height: 20)
        detailLabel.frame = NSRect(x: 12, y: 11, width: bounds.width - 24, height: bounds.height - 47)
    }
}
