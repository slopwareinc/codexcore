import AppKit
import CodexCore
import Foundation
import SwiftUI

struct CodexTranscriptRenderItemID: Hashable, Sendable {
    var rawValue: String
}

struct CodexTranscriptFileCitationCandidate: Sendable, Equatable {
    var reference: CodexTranscriptFileReference
    var range: NSRange
}

enum CodexTranscriptFileCitationParser {
    private static let expression = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9@])((?:/|\.\.?/)?(?:[A-Za-z0-9_@+~.-]+/)*[A-Za-z0-9_@+~-]+\.[A-Za-z][A-Za-z0-9]{0,11})(?::([1-9][0-9]*))?(?::([1-9][0-9]*))?"#
    )

    static func candidates(in text: String) -> [CodexTranscriptFileCitationCandidate] {
        guard let expression else { return [] }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: fullRange).compactMap { match in
            guard let pathRange = Range(match.range(at: 1), in: text) else { return nil }
            let path = String(text[pathRange])
            guard isPlausible(path: path, hasLine: match.range(at: 2).location != NSNotFound) else {
                return nil
            }
            let line = integer(at: 2, match: match, text: text)
            let column = integer(at: 3, match: match, text: text)
            return CodexTranscriptFileCitationCandidate(
                reference: .init(path: path, line: line, column: column),
                range: match.range(at: 0)
            )
        }
    }

    private static func integer(at index: Int, match: NSTextCheckingResult, text: String) -> Int? {
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        return Int(text[range])
    }

    private static func isPlausible(path: String, hasLine: Bool) -> Bool {
        if path.contains("/") || hasLine { return true }
        let knownWorkspaceNames: Set<String> = [
            "AGENTS.md", "CLAUDE.md", "CONTRIBUTING.md", "Dockerfile", "Gemfile",
            "Justfile", "LICENSE", "Makefile", "Package.swift", "Podfile", "README.md",
        ]
        return knownWorkspaceNames.contains(path)
    }
}

enum CodexTranscriptFileCitationLink {
    static func url(for reference: CodexTranscriptFileReference) -> URL? {
        var components = URLComponents()
        components.scheme = "codex-file"
        components.host = "workspace"
        components.queryItems = [URLQueryItem(name: "path", value: reference.path)]
        if let line = reference.line {
            components.queryItems?.append(URLQueryItem(name: "line", value: String(line)))
        }
        if let column = reference.column {
            components.queryItems?.append(URLQueryItem(name: "column", value: String(column)))
        }
        return components.url
    }

    static func reference(from value: Any) -> CodexTranscriptFileReference? {
        let url: URL?
        if let candidate = value as? URL { url = candidate }
        else if let candidate = value as? String { url = URL(string: candidate) }
        else { url = nil }
        guard let url, url.scheme == "codex-file",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems
        else { return nil }
        var path: String?
        var line: String?
        var column: String?
        var sawPath = false
        var sawLine = false
        var sawColumn = false
        for item in queryItems {
            switch item.name {
            case "path" where !sawPath:
                path = item.value
                sawPath = true
            case "line" where !sawLine:
                line = item.value
                sawLine = true
            case "column" where !sawColumn:
                column = item.value
                sawColumn = true
            default:
                continue
            }
        }
        guard let path else { return nil }
        return .init(path: path, line: line.flatMap(Int.init), column: column.flatMap(Int.init))
    }
}

struct CodexTranscriptColumnMetrics: Sendable, Equatable {
    static let horizontalMargin: CGFloat = 24
    static let flowLayoutHorizontalAllowance: CGFloat = 32
    static let turnGap: CGFloat = 16
    static let itemGap: CGFloat = 4
    static let userBubbleHorizontalPadding: CGFloat = 12
    static let userBubbleVerticalPadding: CGFloat = 8
    static let workHeaderHeight: CGFloat = 22
    static let workRowHeight: CGFloat = 28
    static let footerHeight: CGFloat = 22
    static let actionCardHeight: CGFloat = 32
    static let actionCardRadius: CGFloat = 10
    static let interactiveBottomSpacing: CGFloat = 4
    static let scrollableOutputMaxHeight: CGFloat = 220
    static let diffPanelHeight: CGFloat = 240
    // The workspace title bar floats over the transcript host. Reserve the same
    // clearance used by the turn navigator so the first turn never scrolls
    // underneath that chrome.
    static let topContentInset: CGFloat = 72

    var viewportWidth: CGFloat

    // This is only an AppKit flow-layout constraint. Cells position visible
    // content against the preserved full `viewportWidth`, so it is not a gutter.
    var cellWidth: CGFloat { max(1, viewportWidth - Self.flowLayoutHorizontalAllowance) }

    func outerWidth(_ theme: CodexTranscriptAppKitTheme) -> CGFloat {
        min(
            max(1, viewportWidth - Self.horizontalMargin * 2),
            theme.transcriptOuterMaxWidth
        )
    }

    func contentWidth(
        for policy: CodexTranscriptContentWidthPolicy,
        theme: CodexTranscriptAppKitTheme
    ) -> CGFloat {
        let outerWidth = outerWidth(theme)
        return switch policy {
        case .full: outerWidth
        case .card: min(outerWidth, theme.cardMaxWidth)
        case .user: min(outerWidth * 0.77, theme.userBubbleMaxWidth)
        }
    }
}

enum CodexTranscriptContentWidthPolicy: Sendable, Equatable {
    case full
    case card
    case user
}

enum CodexTranscriptTextRole: Sendable, Equatable {
    case user
    case commentary
    case finalAnswer
    case notice
    case expandedOutput
    case liveTail
    case timestamp
}

enum CodexTranscriptRenderAction: Sendable, Equatable {
    case toggleWork(turnID: String)
    case toggleBookmark(turnID: String)
    case toggleRow(rowID: String)
    case selectDiffFile(rowID: String, index: Int)
    case openSubagent(threadID: String)
    case openThread(CodexThreadReferenceV2)
    case openURL(String)
    case openFile(path: String, line: Int?)
    case openReview(CodexTranscriptReviewRequest)
    case resolveApproval(requestID: CodexServerRequestKey, approve: Bool)
    case retryTurn(turnID: String)
}

struct CodexTranscriptApprovalRender: Sendable, Equatable {
    var requestID: CodexServerRequestKey
    var summary: String
}

struct CodexTranscriptDirectiveRender: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case createdThread(threadID: String?, pendingWorktreeID: String?)
        case gitAction(verb: String, branch: String?, cwd: String?)
        case pullRequest(url: String, branch: String?, isDraft: Bool)
        case codeComment(title: String, body: String, file: String, start: Int?, end: Int?, priority: Int?)
        case unknown(name: String)
    }

    var kind: Kind
    var raw: String
}

struct CodexTranscriptWorkHeaderRender: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case working(startedAt: Date, showsDuration: Bool)
        case done(durationMs: Int?, isExpanded: Bool)
        case interrupted(durationMs: Int?, message: String)
        case failed(message: String)
    }

    var state: State
}

enum CodexTranscriptWorkRowStyle: Sendable, Equatable {
    case standard
    case inlineActivity
    case activitySummary

    var isSemanticActivity: Bool { self != .standard }
}

struct CodexTranscriptWorkRowRender: Sendable, Equatable {
    var kind: CodexWorkRowKind
    var label: String
    var status: CodexWorkItemStatusV2
    var systemImage: String? = nil
    var style: CodexTranscriptWorkRowStyle = .standard
    var durationMs: Int?
    var exitCode: Int? = nil
    var isExpanded: Bool
    var hasDetail: Bool
    var isSubagentLink: Bool
}

struct CodexTranscriptAgentChipRender: Sendable, Equatable {
    var id: String
    var label: String
    var systemImage: String? = nil
    var status: CodexAgentDisplayStatusV2
    var threadID: String?
    var taskSummary: String?
    var latestUpdate: String?
    var attachmentKind: CodexReferencedFile.Kind? = nil
    var imagePreviewSize: CGFloat = 64
    var imagePreviewAspectRatio: CGFloat = 1

    var imagePreviewHeight: CGFloat {
        imagePreviewSize / max(0.01, imagePreviewAspectRatio)
    }
}

enum CodexWorkRowKind: Sendable, Equatable {
    case command, fileChange, mcp, webSearch, agent, other
}

struct CodexTranscriptCodeRender: Sendable, Equatable {
    var language: String?
    var code: String
}

struct CodexTranscriptFooterRender: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case user
        case finalAnswer
    }

    var kind: Kind
    var timestamp: String
    var isTurnStreaming: Bool
}

final class CodexPreparedTranscriptText: @unchecked Sendable {
    let attributedString: NSAttributedString

    init(_ attributedString: NSAttributedString) {
        self.attributedString = attributedString
    }
}

enum CodexTranscriptCopyPayload: @unchecked Sendable {
    case text(String)
    case exactPatch(CodexExactPatchSliceV2)

    func materialized() -> String {
        switch self {
        case .text(let text):
            text
        case .exactPatch(let slice):
            slice.materialized()
        }
    }
}

struct CodexTranscriptRenderItem: @unchecked Sendable {
    var id: CodexTranscriptRenderItemID
    var sectionID: String
    var turnID: String
    var revision: Int
    var textRole: CodexTranscriptTextRole?
    var preparedText: CodexPreparedTranscriptText?
    var workHeader: CodexTranscriptWorkHeaderRender?
    var workRow: CodexTranscriptWorkRowRender?
    var agentChips: [CodexTranscriptAgentChipRender]
    var diffPanel: CodexTranscriptDiffPanelRender?
    var turnDiff: CodexTranscriptTurnDiffRender?
    var code: CodexTranscriptCodeRender?
    var footer: CodexTranscriptFooterRender?
    var productTool: CodexProductToolCallV2?
    /// Renderer-independent typed node selected by the render registry. Legacy
    /// fields remain for compatibility with the existing AppKit cell adapter.
    var renderNode: CodexTranscriptRenderNodeV2?
    var directive: CodexTranscriptDirectiveRender?
    var approval: CodexTranscriptApprovalRender?
    var action: CodexTranscriptRenderAction?
    var copyPayload: CodexTranscriptCopyPayload?
    var editUserText: String?
    var retryUserMessage: CodexUserMessageV2?
    var copyTurnText: String
    var allowsTextSelection: Bool
    var allowsResponseAnnotation: Bool = false
    var accessibilityLabel: String
    var indentation: CGFloat
    var isTrailingAligned: Bool
    var maxContentWidth: CGFloat
    var contentWidthPolicy: CodexTranscriptContentWidthPolicy
    var intrinsicContentWidth: CGFloat?
    var viewportWidth: CGFloat
    var measuredHeight: CGFloat
    var bottomSpacing: CGFloat
    var isScrollableOutput: Bool

    /// Compatibility access for callers that explicitly request copy text.
    /// AppKit visibility paths inspect `copyPayload` and avoid materializing a
    /// legacy exact-patch slice.
    var copyText: String? {
        get { copyPayload?.materialized() }
        set { copyPayload = newValue.map(CodexTranscriptCopyPayload.text) }
    }
}

struct CodexTranscriptRenderDiagnostics: Sendable, Equatable {
    var projectionCount = 0
    var projectedItemCount = 0
    var changedItemCount = 0
    var heightCacheHitCount = 0
    var heightCacheMissCount = 0
    var preparedTextCacheHitCount = 0
    var preparedTextCacheMissCount = 0
    var markdownProjectionCount = 0
    var projectionDurationMilliseconds: Double = 0
}

struct CodexTranscriptRenderSnapshot: @unchecked Sendable {
    var threadID: String
    var sectionIDs: [String]
    var itemIDsBySection: [String: [CodexTranscriptRenderItemID]]
    /// The flattened display order is shared by collection, find, and minimap
    /// paths. Keep it with the immutable snapshot so repeated reads do not
    /// allocate and flatten every section again.
    let orderedItemIDs: [CodexTranscriptRenderItemID]
    var itemsByID: [CodexTranscriptRenderItemID: CodexTranscriptRenderItem]
    var changedItemIDs: Set<CodexTranscriptRenderItemID>
    var diagnostics: CodexTranscriptRenderDiagnostics
}

struct CodexTranscriptAppKitTheme: @unchecked Sendable {
    var bodyFont: NSFont
    var codeFont: NSFont
    var captionFont: NSFont
    var microFont: NSFont
    var textPrimary: NSColor
    var textSecondary: NSColor
    var textTertiary: NSColor
    var userBubble: NSColor
    var userBubbleStroke: NSColor
    var codeBackground: NSColor
    var codeHeader: NSColor
    var codeText: NSColor
    var codeFaint: NSColor
    var surfaceSunken: NSColor
    var border: NSColor
    var success: NSColor
    var danger: NSColor
    var running: NSColor
    var warning: NSColor
    var accent: NSColor
    var codeKeyword: NSColor
    var codeString: NSColor
    var codeComment: NSColor
    var codeNumber: NSColor
    var bubbleRadius: CGFloat
    var cardRadius: CGFloat
    var lineSpacing: CGFloat
    var cardMaxWidth: CGFloat
    var userBubbleMaxWidth: CGFloat
    var transcriptOuterMaxWidth: CGFloat
    var fingerprint: String

    /// - Parameter colorScheme: The appearance to resolve against. Required
    ///   because `NSColor(someAdaptiveSwiftUIColor)` resolves against the
    ///   process appearance, not this window's, so an app pinned to light while
    ///   the system is dark would render the transcript in the wrong palette.
    @MainActor
    init(_ theme: CodexAgentTheme, colorScheme: ColorScheme) {
        // Flatten every color to a static sRGB value for `colorScheme`. Two
        // reasons, both load-bearing:
        //
        // 1. Correctness. Theme colors are appearance-adaptive, and a dynamic
        //    NSColor resolves against the *process* appearance when drawn by
        //    AppKit. An app pinned to Light while the system is Dark would draw
        //    the transcript from the dark palette.
        // 2. Stability. `fingerprint` gates a full reconfigure of every cell.
        //    A dynamic NSColor's `description` is not stable across equal
        //    values, so fingerprinting one made the transcript reconfigure all
        //    items on every single update.
        let resolve = CodexTranscriptAppKitTheme.staticColorResolver(for: colorScheme)

        bodyFont = theme.fonts.chatNSFont ?? .systemFont(ofSize: 15)
        codeFont = theme.fonts.codeNSFont ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        captionFont = .systemFont(ofSize: max(10, bodyFont.pointSize - 2))
        microFont = .monospacedSystemFont(ofSize: max(9, bodyFont.pointSize - 3), weight: .semibold)
        textPrimary = resolve(theme.colors.textPrimary)
        textSecondary = resolve(theme.colors.textSecondary)
        textTertiary = resolve(theme.colors.textTertiary)
        userBubble = resolve(theme.colors.userBubble)
        userBubbleStroke = resolve(theme.colors.userBubbleStroke)
        codeBackground = resolve(theme.colors.codeBackground)
        codeHeader = resolve(theme.colors.codeHeader)
        codeText = resolve(theme.colors.codeText)
        codeFaint = resolve(theme.colors.codeFaint)
        surfaceSunken = resolve(theme.colors.surfaceSunken)
        border = resolve(theme.colors.border)
        success = resolve(theme.colors.success)
        danger = resolve(theme.colors.danger)
        running = resolve(theme.colors.running)
        warning = resolve(theme.colors.warning)
        accent = resolve(theme.colors.accent)
        codeKeyword = resolve(theme.colors.codeKeyword)
        codeString = resolve(theme.colors.codeString)
        codeComment = resolve(theme.colors.codeComment)
        codeNumber = resolve(theme.colors.codeNumber)
        bubbleRadius = theme.radii.bubble
        cardRadius = theme.radii.medium
        lineSpacing = theme.spacing.chatLineSpacing
        cardMaxWidth = theme.spacing.cardMaxWidth
        userBubbleMaxWidth = theme.spacing.userBubbleMaxWidth
        transcriptOuterMaxWidth = theme.spacing.transcriptOuterMaxWidth
        fingerprint = [
            String(describing: colorScheme),
            bodyFont.fontName, String(describing: bodyFont.pointSize), codeFont.fontName,
            String(describing: codeFont.pointSize),
            Self.colorFingerprint(textPrimary),
            Self.colorFingerprint(userBubble), Self.colorFingerprint(codeHeader),
            Self.colorFingerprint(codeKeyword), Self.colorFingerprint(codeString),
            Self.colorFingerprint(codeComment), Self.colorFingerprint(codeNumber),
            Self.colorFingerprint(accent), Self.colorFingerprint(warning),
            String(describing: lineSpacing)
        ].joined(separator: ":")
    }

    /// Stable identity for a resolved color.
    ///
    /// `String(describing:)` must never be used here. `staticColorResolver`
    /// flattens to sRGB but falls back to the dynamic color when conversion
    /// fails, and a dynamic `NSColor`'s description is not stable across equal
    /// values — each projection builds fresh instances, so the theme
    /// fingerprint changed on every update and reconfigured all 1,085 items
    /// instead of the one that actually changed. It reproduced only on a
    /// headless runner, where the sRGB conversion is the part that fails.
    ///
    /// Components are stable whenever conversion succeeds, and the failure case
    /// degrades to a constant: a theme change may then go unnoticed, which
    /// costs a stale palette until the next structural update, while the
    /// alternative costs a full reconfigure on every keystroke of streamed text.
    private static func colorFingerprint(_ color: NSColor) -> String {
        guard let srgb = color.usingColorSpace(.sRGB) else { return "unresolved" }
        return String(
            format: "%.4f/%.4f/%.4f/%.4f",
            srgb.redComponent,
            srgb.greenComponent,
            srgb.blueComponent,
            srgb.alphaComponent
        )
    }

    /// Returns a function that flattens a SwiftUI `Color` — adaptive or not —
    /// into a static sRGB `NSColor` for the given appearance. See
    /// `CodexAppKitColor` for why this must go through
    /// `performAsCurrentDrawingAppearance` rather than a plain `NSColor(_:)`.
    @MainActor
    static func staticColorResolver(for colorScheme: ColorScheme) -> (Color) -> NSColor {
        { color in CodexAppKitColor.resolve(color, for: colorScheme) }
    }
}

actor CodexTranscriptRenderProjector {
    private struct RevisionState {
        var fingerprint: String
        var revision: Int
    }

    private struct HeightKey: Hashable {
        var id: CodexTranscriptRenderItemID
        var revision: Int
        var widthPixels: Int
        var theme: String
    }

    private struct ProjectionCacheSignature: Equatable {
        var threadID: String
        var widthPixels: Int
        var theme: String
    }

    private struct CachedTurnSection {
        var sectionID: String
        var itemIDs: [CodexTranscriptRenderItemID]
        var itemsByID: [CodexTranscriptRenderItemID: CodexTranscriptRenderItem]
    }

    private var previousBlocksBySourceID: [String: [CodexBlock]] = [:]
    private var sourceTextBySourceID: [String: String] = [:]
    private var revisionByID: [CodexTranscriptRenderItemID: RevisionState] = [:]
    private var heightByKey: [HeightKey: CGFloat] = [:]
    private var preparedTextByKey: [String: CodexPreparedTranscriptText] = [:]
    private var preparedTextInsertionOrder: [String] = []
    private var preparedDiffText: (
        key: String,
        text: CodexPreparedTranscriptText
    )?
    private var imageAspectRatioBySource: [String: CGFloat] = [:]
    private var projectionCount = 0
    private var cachedProjectionSignature: ProjectionCacheSignature?
    private var cachedSectionsByTurnID: [String: CachedTurnSection] = [:]
    private let codeHighlighter: any CodexCodeHighlighter = CodexRegexCodeHighlighter()
    private let rendererRegistry = CodexTranscriptRendererRegistry.default

    func project(
        presentation: CodexThreadUIPresentation,
        availableWidth: CGFloat,
        theme: CodexTranscriptAppKitTheme,
        dirtyTurnIDs: Set<String>? = nil
    ) throws -> CodexTranscriptRenderSnapshot {
        try Task.checkCancellation()
        let startedAt = ContinuousClock.now
        let contentWidth = CodexTranscriptColumnMetrics(viewportWidth: availableWidth).outerWidth(theme)
        var sections: [String] = []
        var itemIDsBySection: [String: [CodexTranscriptRenderItemID]] = [:]
        var itemsByID: [CodexTranscriptRenderItemID: CodexTranscriptRenderItem] = [:]
        var changedIDs: Set<CodexTranscriptRenderItemID> = []
        var liveIDs: Set<CodexTranscriptRenderItemID> = []
        var cacheHits = 0
        var cacheMisses = 0
        var preparedTextCacheHits = 0
        var preparedTextCacheMisses = 0
        var markdownProjections = 0
        let projectionSignature = ProjectionCacheSignature(
            threadID: presentation.threadID,
            widthPixels: Int((availableWidth * 2).rounded()),
            theme: theme.fingerprint
        )
        let reusesUnchangedTurns = dirtyTurnIDs != nil
            && cachedProjectionSignature == projectionSignature
        if !reusesUnchangedTurns {
            cachedProjectionSignature = projectionSignature
            cachedSectionsByTurnID.removeAll(keepingCapacity: true)
        }
        var liveTurnIDs: Set<String> = []
        liveTurnIDs.reserveCapacity(presentation.transcript.turns.count)

        for turn in presentation.transcript.turns {
            try Task.checkCancellation()
            let sectionID = "\(presentation.threadID):turn:\(turn.id)"
            liveTurnIDs.insert(turn.id)
            if reusesUnchangedTurns,
               dirtyTurnIDs?.contains(turn.id) == false,
               let cached = cachedSectionsByTurnID[turn.id] {
                sections.append(cached.sectionID)
                itemIDsBySection[cached.sectionID] = cached.itemIDs
                for (id, item) in cached.itemsByID {
                    itemsByID[id] = item
                    liveIDs.insert(id)
                }
                continue
            }
            sections.append(sectionID)
            var sectionItems: [CodexTranscriptRenderItemID] = []
            let copyTurnText = Self.copyText(for: turn)
            let presentedAt = presentation.presentedAtByTurnID[turn.id] ?? Date()
            let turnIsStreaming = Self.isStreaming(turn)

            func append(_ draft: ItemDraft) {
                let id = CodexTranscriptRenderItemID(rawValue: draft.id)
                let allowsTextSelection = draft.footer == nil
                    && (draft.preparedText != nil || draft.code != nil)
                let allowsResponseAnnotation = allowsTextSelection
                    && draft.textRole == .finalAnswer
                    && !turnIsStreaming
                let contentFingerprint = CodexBlockDigest.digest(draft.fingerprint)
                let previous = revisionByID[id]
                let revision: Int
                if previous?.fingerprint == contentFingerprint {
                    revision = previous?.revision ?? 0
                } else {
                    revision = (previous?.revision ?? -1) + 1
                    changedIDs.insert(id)
                }
                revisionByID[id] = RevisionState(fingerprint: contentFingerprint, revision: revision)
                let maxWidth = draft.maxWidth(contentWidth, theme)
                let heightKey = HeightKey(
                    id: id,
                    revision: revision,
                    widthPixels: Int((maxWidth * 2).rounded()),
                    theme: theme.fingerprint
                )
                let measuredHeight: CGFloat
                if let cached = heightByKey[heightKey] {
                    measuredHeight = cached
                    cacheHits += 1
                } else {
                    measuredHeight = Self.measure(draft: draft, width: maxWidth, theme: theme)
                    heightByKey[heightKey] = measuredHeight
                    cacheMisses += 1
                }
                let item = CodexTranscriptRenderItem(
                    id: id,
                    sectionID: sectionID,
                    turnID: turn.id,
                    revision: revision,
                    textRole: draft.textRole,
                    preparedText: draft.preparedText,
                    workHeader: draft.workHeader,
                    workRow: draft.workRow,
                    agentChips: draft.agentChips,
                    diffPanel: draft.diffPanel,
                    turnDiff: draft.turnDiff,
                    code: draft.code,
                    footer: draft.footer,
                    productTool: draft.productTool,
                    renderNode: draft.renderNode,
                    directive: draft.directive,
                    approval: draft.approval,
                    action: draft.action,
                    copyPayload: draft.copyPayload,
                    editUserText: draft.editUserText,
                    retryUserMessage: Self.retryUserMessage(for: draft, turn: turn),
                    copyTurnText: copyTurnText,
                    allowsTextSelection: allowsTextSelection,
                    allowsResponseAnnotation: allowsResponseAnnotation,
                    accessibilityLabel: draft.accessibilityLabel,
                    indentation: draft.indentation,
                    isTrailingAligned: draft.isTrailingAligned,
                    maxContentWidth: maxWidth,
                    contentWidthPolicy: draft.maxWidthKind,
                    intrinsicContentWidth: draft.intrinsicContentWidth,
                    viewportWidth: availableWidth,
                    measuredHeight: measuredHeight,
                    bottomSpacing: draft.bottomSpacing,
                    isScrollableOutput: draft.isScrollableOutput
                )
                sectionItems.append(id)
                itemsByID[id] = item
                liveIDs.insert(id)
            }

            if let user = turn.userMessage {
                for draft in userMessageDrafts(
                    user,
                    sectionID: sectionID,
                    contentWidth: contentWidth,
                    turnIsStreaming: turnIsStreaming,
                    hidesTimestamp: turn.presentationStyle == .realtimeVoice,
                    theme: theme,
                    cacheHits: &preparedTextCacheHits,
                    cacheMisses: &preparedTextCacheMisses
                ) { append(draft) }
            }

            if presentation.bookmarkedTurnIDs.contains(turn.id) {
                let bookmark = CodexTranscriptWorkRowRender(
                    kind: .other,
                    label: "Bookmarked turn",
                    status: .completed,
                    systemImage: "bookmark.fill",
                    style: .inlineActivity,
                    durationMs: nil,
                    isExpanded: false,
                    hasDetail: false,
                    isSubagentLink: false
                )
                append(ItemDraft(
                    id: "\(sectionID):bookmark",
                    fingerprint: "bookmark:\(turn.id)",
                    workRow: bookmark,
                    action: .toggleBookmark(turnID: turn.id),
                    accessibilityLabel: "Bookmarked turn",
                    maxWidthKind: .card,
                    fixedHeight: CodexTranscriptColumnMetrics.workRowHeight
                ))
            }
            if let badge = presentation.outputBadgesByTurnID[turn.id],
               !badge.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let output = CodexTranscriptWorkRowRender(
                    kind: .other,
                    label: String(badge.prefix(120)),
                    status: .completed,
                    systemImage: "checkmark.seal",
                    style: .inlineActivity,
                    durationMs: nil,
                    isExpanded: false,
                    hasDetail: false,
                    isSubagentLink: false
                )
                append(ItemDraft(
                    id: "\(sectionID):output-badge",
                    fingerprint: "output-badge:\(badge)",
                    workRow: output,
                    accessibilityLabel: "Output badge: \(badge)",
                    maxWidthKind: .card,
                    fixedHeight: CodexTranscriptColumnMetrics.workRowHeight
                ))
            }

            let showsWork = turn.presentationStyle == .realtimeVoice
                ? false
                : Self.shouldRenderWork(turn)
            let tailMode = Self.isWorkTailMode(turn)
            let workExpanded = Self.workIsExpanded(turn, presentation: presentation)
            let turnDiff = Self.turnDiffRender(
                turn: turn,
                isExpanded: presentation.expandedRowIDs.contains("turn-diff:\(turn.id)")
            )
            if showsWork {
                let header = Self.workHeader(turn, expanded: workExpanded, presentedAt: presentedAt)
                append(ItemDraft(
                    id: "\(sectionID):work-header",
                    fingerprint: "work:\(String(describing: header.state))",
                    workHeader: header,
                    action: Self.workHeaderIsActionable(header) ? .toggleWork(turnID: turn.id) : nil,
                    accessibilityLabel: Self.workHeaderAccessibilityLabel(header),
                    maxWidthKind: .card,
                    fixedHeight: CodexTranscriptColumnMetrics.workHeaderHeight
                ))
                if turn.id == presentation.transcript.turns.last?.id,
                   case .working = turn.status {
                    for prompt in presentation.pendingApprovals {
                        let summary = (prompt.primaryValue ?? prompt.detail)
                            .split(separator: "\n", maxSplits: 1).first.map(String.init) ?? prompt.title
                        append(ItemDraft(
                            id: "\(sectionID):approval:\(prompt.id.presentationID)",
                            fingerprint: "approval:\(prompt.id.presentationID):\(summary)",
                            approval: .init(requestID: prompt.id, summary: summary),
                            accessibilityLabel: "Approval needed — \(summary)",
                            maxWidthKind: .card,
                            fixedHeight: 74
                        ))
                    }
                }
            }

            if showsWork && workExpanded {
                for segment in turn.conversationSegments {
                    if let user = segment.steeredMessage {
                        for draft in userMessageDrafts(
                            user,
                            sectionID: sectionID,
                            contentWidth: contentWidth,
                            turnIsStreaming: turnIsStreaming,
                            hidesTimestamp: turn.presentationStyle == .realtimeVoice,
                            theme: theme,
                            cacheHits: &preparedTextCacheHits,
                            cacheMisses: &preparedTextCacheMisses
                        ) { append(draft) }
                    }
                    for entry in segment.narrative {
                        try Task.checkCancellation()
                        switch entry {
                    case .prose(let prose):
                        if tailMode { continue }
                        let sourceID = "\(sectionID):commentary:\(prose.id)"
                        for draft in contentDrafts(
                            text: prose.text, streaming: prose.isStreaming, sourceID: sourceID,
                            role: .commentary, theme: theme, cacheHits: &preparedTextCacheHits,
                            cacheMisses: &preparedTextCacheMisses, markdownProjections: &markdownProjections
                        ) { append(draft) }
                        if let citationDraft = memoryCitationDraft(
                            citations: prose.memoryCitations,
                            sectionID: sectionID,
                            sourceID: prose.id,
                            theme: theme
                        ) {
                            append(citationDraft)
                        }
                    case .workGroup(let group):
                        let rows = tailMode ? group.rows.filter(\.isInProgress) : group.rows
                        if rows.isEmpty { continue }
                        let groupHeader = CodexWorkGroupPresentationV2.header(
                            group,
                            rows: tailMode ? rows : nil
                        )
                        let groupIsExpanded = presentation.expandedRowIDs.contains(group.id)
                        let groupStatus = CodexWorkGroupPresentationV2.status(
                            rows: rows,
                            isLive: tailMode || group.isLive
                        )
                        let summaryRender = CodexTranscriptWorkRowRender(
                            kind: .other,
                            label: groupHeader,
                            status: groupStatus,
                            systemImage: CodexWorkGroupPresentationV2.systemImage(rows: rows),
                            style: .activitySummary,
                            durationMs: nil,
                            isExpanded: groupIsExpanded,
                            hasDetail: true,
                            isSubagentLink: false
                        )
                        append(ItemDraft(
                            id: "\(sectionID):group:\(group.id):summary",
                            fingerprint: "group-summary:\(String(describing: summaryRender))",
                            workRow: summaryRender,
                            renderNode: rendererRegistry.node(for: .workGroup(group)),
                            action: .toggleRow(rowID: group.id),
                            accessibilityLabel: "\(groupHeader), \(groupIsExpanded ? "details shown" : "details hidden")",
                            maxWidthKind: .card,
                            fixedHeight: CodexTranscriptColumnMetrics.workRowHeight,
                            bottomSpacing: groupIsExpanded ? 2 : CodexTranscriptColumnMetrics.interactiveBottomSpacing
                        ))
                        if !groupIsExpanded { continue }
                        let agentChips = rows.compactMap { row -> CodexTranscriptAgentChipRender? in
                            guard case .collabAgent(let agent) = row else { return nil }
                            let threadID = agent.agentThreadIDs.first
                            return .init(
                                id: agent.id,
                                label: threadID.flatMap { presentation.agentDisplayNameByThreadID[$0] }
                                    ?? Self.agentChipLabel(agent),
                                status: threadID.flatMap {
                                    presentation.agentDisplayStatusByThreadID[$0]
                                } ?? agent.displayStatus,
                                threadID: threadID,
                                taskSummary: agent.instructions?.codexAppKitNilIfEmpty,
                                latestUpdate: agent.agentMessages.values.first?.codexAppKitNilIfEmpty
                            )
                        }
                        if !agentChips.isEmpty {
                            append(ItemDraft(
                                id: "\(sectionID):group:\(group.id):agents",
                                fingerprint: "agent-chips:\(String(describing: agentChips))",
                                agentChips: agentChips,
                                accessibilityLabel: Self.agentClusterAccessibilityLabel(agentChips),
                                indentation: 0,
                                maxWidthKind: .card,
                                bottomSpacing: CodexTranscriptColumnMetrics.interactiveBottomSpacing
                            ))
                        }
                        for row in rows {
                            if case .collabAgent = row { continue }
                            let rowID = row.id
                            let detail = Self.detail(for: row)
                            let hasFileDetail: Bool = {
                                guard case .fileChange(let value) = row else { return false }
                                return value.hasPreparedDetail
                            }()
                            let hasDetail = detail != nil || hasFileDetail
                            let isRowExpanded = presentation.expandedRowIDs.contains(rowID)
                            let subagentThreadID = Self.subagentThreadID(for: row)
                            let rowRender = CodexTranscriptWorkRowRender(
                                kind: Self.kind(for: row),
                                label: Self.label(for: row),
                                status: Self.status(for: row),
                                systemImage: Self.systemImage(for: row),
                                durationMs: Self.duration(for: row),
                                exitCode: Self.exitCode(for: row),
                                isExpanded: isRowExpanded,
                                hasDetail: hasDetail,
                                isSubagentLink: subagentThreadID != nil
                            )
                            append(ItemDraft(
                                id: "\(sectionID):row:\(rowID)",
                                fingerprint: "row:\(String(describing: rowRender))",
                                workRow: rowRender,
                                renderNode: Self.renderNode(for: row),
                                action: subagentThreadID.map(CodexTranscriptRenderAction.openSubagent)
                                    ?? (hasDetail ? .toggleRow(rowID: rowID) : nil),
                                copyText: detail,
                                accessibilityLabel: Self.accessibilityLabel(for: row, render: rowRender),
                                indentation: 0,
                                maxWidthKind: .card,
                                fixedHeight: CodexTranscriptColumnMetrics.workRowHeight,
                                bottomSpacing: rowRender.isExpanded
                                    ? 2
                                    : CodexTranscriptColumnMetrics.interactiveBottomSpacing
                            ))
                            if isRowExpanded,
                               case .fileChange(let fileChange) = row,
                               let fileChangeRender = Self.fileChangeRenderProjection(
                                   rowID: rowID,
                                   fileChange: fileChange,
                                   requestedIndex: presentation.selectedDiffFileIndexByRowID[rowID] ?? 0
                               ) {
                                let selectedPreparedChange = fileChangeRender.selectedChange
                                let prepared = cachedPreparedText(
                                    content: "", style: "diff-file", theme: theme,
                                    cacheFingerprint: selectedPreparedChange.fingerprint,
                                    cacheHits: &preparedTextCacheHits, cacheMisses: &preparedTextCacheMisses
                                ) {
                                    Self.prepareDiffFile(
                                        selectedPreparedChange,
                                        theme: theme
                                    )
                                }
                                append(ItemDraft(
                                    id: "\(sectionID):row:\(rowID):diff-panel",
                                    fingerprint: "diff-panel:\(fileChangeRender.panel.selectedFileIndex):\(selectedPreparedChange.fingerprint):\(fileChangeRender.panelFingerprint):\(fileChangeRender.panel.omittedFileCount)",
                                    preparedText: prepared,
                                    diffPanel: fileChangeRender.panel,
                                    copyPayload: fileChangeRender.copyPayload,
                                    accessibilityLabel: fileChangeRender.accessibilityLabel,
                                    indentation: 0,
                                    maxWidthKind: .card,
                                    fixedHeight: CodexTranscriptColumnMetrics.diffPanelHeight,
                                    bottomSpacing: CodexTranscriptColumnMetrics.interactiveBottomSpacing,
                                    isScrollableOutput: true
                                ))
                            } else if isRowExpanded, let detail {
                                let bounded = Self.bounded(detail, limit: 20_000)
                                let prepared = cachedPreparedText(
                                    content: bounded,
                                    style: Self.expandedOutputCacheStyle(for: row),
                                    theme: theme,
                                    cacheHits: &preparedTextCacheHits,
                                    cacheMisses: &preparedTextCacheMisses
                                ) {
                                    Self.prepareExpandedOutput(
                                        bounded,
                                        row: row,
                                        theme: theme
                                    )
                                }
                                append(ItemDraft(
                                    id: "\(sectionID):row:\(rowID):detail",
                                    fingerprint: "detail:\(bounded)",
                                    textRole: .expandedOutput,
                                    preparedText: prepared,
                                    copyText: detail,
                                    accessibilityLabel: "Expanded output: \(prepared.attributedString.string)",
                                    indentation: 0,
                                    maxWidthKind: .card,
                                    bottomSpacing: CodexTranscriptColumnMetrics.interactiveBottomSpacing,
                                    isScrollableOutput: true
                                ))
                            }
                        }
                    case .productToolCall(let call):
                        if tailMode, call.status != .inProgress { continue }
                        append(ItemDraft(
                            id: "\(sectionID):product:\(call.id)",
                            fingerprint: "product:\(String(describing: call))",
                            productTool: call,
                            action: CodexProductToolPresentationV2.threadReference(call).map {
                                .openThread($0)
                            },
                            accessibilityLabel: CodexProductToolPresentationV2.accessibilityLabel(call),
                            maxWidthKind: .card,
                            fixedHeight: CodexTranscriptColumnMetrics.workRowHeight,
                            bottomSpacing: CodexTranscriptColumnMetrics.interactiveBottomSpacing
                        ))
                    case .inlineActivity(let activity):
                        if tailMode, activity.status != .inProgress { continue }
                        let detail = activity.detail?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .codexAppKitNilIfEmpty
                        let imagePath = activity.imagePath?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .codexAppKitNilIfEmpty
                        let hasExpandableContent = detail != nil || imagePath != nil
                        let rowID = "\(turn.id):inline-activity:\(activity.id)"
                        let isExpanded = presentation.expandedRowIDs.contains(rowID)
                        let rowRender = CodexTranscriptWorkRowRender(
                            kind: .other,
                            label: activity.label,
                            status: activity.status,
                            systemImage: activity.systemImage,
                            style: .inlineActivity,
                            durationMs: nil,
                            isExpanded: isExpanded,
                            hasDetail: hasExpandableContent,
                            isSubagentLink: false
                        )
                        append(ItemDraft(
                            id: "\(sectionID):inline-activity:\(activity.id)",
                            fingerprint: "inline-activity:\(String(describing: activity))",
                            workRow: rowRender,
                            action: hasExpandableContent ? .toggleRow(rowID: rowID) : nil,
                            copyText: detail,
                            accessibilityLabel: Self.inlineActivityAccessibilityLabel(
                                activity,
                                isExpanded: isExpanded
                            ),
                            maxWidthKind: .card,
                            fixedHeight: CodexTranscriptColumnMetrics.workRowHeight,
                            bottomSpacing: isExpanded
                                ? 2
                                : CodexTranscriptColumnMetrics.interactiveBottomSpacing
                        ))
                        if isExpanded, let imagePath {
                            let label = URL(fileURLWithPath: imagePath).lastPathComponent
                            append(ItemDraft(
                                id: "\(sectionID):inline-activity:\(activity.id):image",
                                fingerprint: "inline-activity-image:\(imagePath)",
                                agentChips: [.init(
                                    id: "\(activity.id):image",
                                    label: label,
                                    status: .done,
                                    threadID: nil,
                                    taskSummary: imagePath,
                                    latestUpdate: nil,
                                    attachmentKind: .image,
                                    imagePreviewSize: 160,
                                    imagePreviewAspectRatio: imageAspectRatio(for: imagePath)
                                )],
                                accessibilityLabel: "Viewed image: \(label)",
                                indentation: 22,
                                maxWidthKind: .card,
                                intrinsicContentWidth: 160,
                                bottomSpacing: detail == nil
                                    ? CodexTranscriptColumnMetrics.interactiveBottomSpacing
                                    : 2
                            ))
                        }
                        if isExpanded, let detail {
                            let bounded = Self.bounded(detail, limit: 20_000)
                            append(ItemDraft(
                                id: "\(sectionID):inline-activity:\(activity.id):detail",
                                fingerprint: "inline-activity-detail:\(bounded)",
                                textRole: .notice,
                                preparedText: Self.preparePlain(
                                    bounded,
                                    font: theme.bodyFont,
                                    color: theme.textSecondary,
                                    theme: theme
                                ),
                                copyText: detail,
                                accessibilityLabel: "Activity details: \(bounded)",
                                indentation: 22,
                                maxWidthKind: .card,
                                bottomSpacing: CodexTranscriptColumnMetrics.interactiveBottomSpacing
                            ))
                        }
                    case .notice(let notice):
                        if tailMode { continue }
                        append(ItemDraft(
                            id: "\(sectionID):notice:\(notice.id)",
                            fingerprint: "notice:\(notice.message)",
                            textRole: .notice,
                            preparedText: Self.preparePlain(notice.message, font: theme.captionFont, color: theme.textTertiary, theme: theme),
                            copyText: notice.message,
                            accessibilityLabel: notice.message,
                            maxWidthKind: .card
                        ))
                    case .structuredCard(let card):
                        if tailMode { continue }
                        let summary = [card.title, card.explanation]
                            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n")
                        append(ItemDraft(
                            id: "\(sectionID):structured-card:\(card.id)",
                            fingerprint: "structured-card:\(String(describing: card))",
                            textRole: .notice,
                            preparedText: Self.preparePlain(summary, font: theme.captionFont, color: theme.textSecondary, theme: theme),
                            renderNode: .structuredCard(card),
                            copyText: summary,
                            accessibilityLabel: "\(card.title), structured card",
                            maxWidthKind: .card
                        ))
                    case .approvalReview(let review):
                        if tailMode { continue }
                        let summary = [review.title, review.statusLabel, review.rationale]
                            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n")
                        append(ItemDraft(
                            id: "\(sectionID):approval-review:\(review.id)",
                            fingerprint: "approval-review:\(String(describing: review))",
                            textRole: .notice,
                            preparedText: Self.preparePlain(summary, font: theme.captionFont, color: theme.warning, theme: theme),
                            renderNode: .approvalReview(review),
                            copyText: summary,
                            accessibilityLabel: "\(review.title), \(review.statusLabel)",
                            maxWidthKind: .card
                        ))
                    case .hookActivity(let hook):
                        if tailMode { continue }
                        let summary = [hook.label, hook.statusMessage]
                            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n")
                        append(ItemDraft(
                            id: "\(sectionID):hook:\(hook.id)",
                            fingerprint: "hook:\(String(describing: hook))",
                            textRole: .notice,
                            preparedText: Self.preparePlain(summary, font: theme.captionFont, color: theme.textSecondary, theme: theme),
                            renderNode: .hookActivity(hook),
                            copyText: summary,
                            accessibilityLabel: "\(hook.label), hook \(Self.statusTitle(hook.status))",
                            maxWidthKind: .card
                        ))
                    case .recovery(let recovery):
                        let summary = recovery.message
                        append(ItemDraft(
                            id: "\(sectionID):recovery:\(recovery.id)",
                            fingerprint: "recovery:\(String(describing: recovery))",
                            textRole: .notice,
                            preparedText: Self.preparePlain(summary, font: theme.captionFont, color: theme.warning, theme: theme),
                            renderNode: .recovery(recovery),
                            action: recovery.canRetry && turn.userMessage != nil
                                ? .retryTurn(turnID: turn.id)
                                : nil,
                            copyText: summary,
                            accessibilityLabel: summary,
                            maxWidthKind: .card
                        ))
                        }
                    }
                }
                if case .working = turn.status,
                   let tail = turn.liveTail?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !tail.isEmpty,
                   CodexWorkBlockViewV2.shouldRenderLiveTail(
                       narrative: turn.narrative,
                       liveTail: tail
                   ) {
                    append(ItemDraft(
                        id: "\(sectionID):live-tail",
                        fingerprint: "tail:\(tail)",
                        textRole: .liveTail,
                        preparedText: Self.preparePlain(tail, font: theme.captionFont, color: theme.textTertiary, theme: theme),
                        accessibilityLabel: tail,
                        maxWidthKind: .card,
                        fixedHeight: 28
                    ))
                }
            } else {
                for user in turn.steeredMessages {
                    for draft in userMessageDrafts(
                        user,
                        sectionID: sectionID,
                        contentWidth: contentWidth,
                        turnIsStreaming: turnIsStreaming,
                        hidesTimestamp: turn.presentationStyle == .realtimeVoice,
                        theme: theme,
                        cacheHits: &preparedTextCacheHits,
                        cacheMisses: &preparedTextCacheMisses
                    ) { append(draft) }
                }
            }

            // Failed turns keep recovery affordances visible even while their
            // historical work disclosure is collapsed.
            if !workExpanded, case .failed = turn.status {
                for recovery in turn.recoveryNotices {
                    let summary = recovery.message
                    append(ItemDraft(
                        id: "\(sectionID):recovery:\(recovery.id)",
                        fingerprint: "recovery:\(String(describing: recovery))",
                        textRole: .notice,
                        preparedText: Self.preparePlain(summary, font: theme.captionFont, color: theme.warning, theme: theme),
                        renderNode: .recovery(recovery),
                        action: recovery.canRetry && turn.userMessage != nil
                            ? .retryTurn(turnID: turn.id)
                            : nil,
                        copyText: summary,
                        accessibilityLabel: summary,
                        maxWidthKind: .card
                    ))
                }
            }
            if !workExpanded, case .done = turn.status {
                for card in turn.structuredCards {
                    let summary = card.title
                    append(ItemDraft(
                        id: "\(sectionID):structured-card:\(card.id)",
                        fingerprint: "structured-card:\(String(describing: card))",
                        textRole: .notice,
                        preparedText: Self.preparePlain(summary, font: theme.captionFont, color: theme.textSecondary, theme: theme),
                        renderNode: .structuredCard(card),
                        copyText: summary,
                        accessibilityLabel: "\(summary), structured card",
                        maxWidthKind: .card
                    ))
                }
                for review in turn.approvalReviews {
                    let summary = "\(review.title): \(review.statusLabel)"
                    append(ItemDraft(
                        id: "\(sectionID):approval-review:\(review.id)",
                        fingerprint: "approval-review:\(String(describing: review))",
                        textRole: .notice,
                        preparedText: Self.preparePlain(summary, font: theme.captionFont, color: theme.warning, theme: theme),
                        renderNode: .approvalReview(review),
                        copyText: summary,
                        accessibilityLabel: summary,
                        maxWidthKind: .card
                    ))
                }
                for hook in turn.hookActivities {
                    let summary = "\(hook.label): \(Self.statusTitle(hook.status))"
                    append(ItemDraft(
                        id: "\(sectionID):hook:\(hook.id)",
                        fingerprint: "hook:\(String(describing: hook))",
                        textRole: .notice,
                        preparedText: Self.preparePlain(summary, font: theme.captionFont, color: theme.textSecondary, theme: theme),
                        renderNode: .hookActivity(hook),
                        copyText: summary,
                        accessibilityLabel: summary,
                        maxWidthKind: .card
                    ))
                }
            }

            if let turnDiff {
                let rowHeight = CodexTranscriptTurnDiffCard.rowHeight
                let disclosureHeight: CGFloat = turnDiff.hiddenFileCount > 0 || turnDiff.isExpanded
                    ? rowHeight : 0
                append(ItemDraft(
                    id: "\(sectionID):turn-diff",
                    fingerprint: "turn-diff:\(String(describing: turnDiff))",
                    turnDiff: turnDiff,
                    accessibilityLabel: "\(turnDiff.title), \(turnDiff.totalAdded) additions and \(turnDiff.totalRemoved) removals",
                    maxWidthKind: .card,
                    fixedHeight: CodexTranscriptTurnDiffCard.topSpacing
                        + CodexTranscriptTurnDiffCard.headerHeight
                        + CodexTranscriptTurnDiffCard.listVerticalInset * 2
                        + CGFloat(turnDiff.visibleFiles.count) * rowHeight
                        + disclosureHeight,
                    // A card carries more visual weight than a text line, so it
                    // gets a full gap instead of the tight interactive spacing.
                    bottomSpacing: CodexTranscriptColumnMetrics.turnGap
                ))
            }

            if let answer = turn.finalAnswer, !answer.text.isEmpty {
                let sourceID = "\(sectionID):final:\(answer.id)"
                for draft in contentDrafts(
                    text: answer.text, streaming: answer.isStreaming, sourceID: sourceID,
                    role: .finalAnswer, theme: theme, cacheHits: &preparedTextCacheHits,
                    cacheMisses: &preparedTextCacheMisses, markdownProjections: &markdownProjections
                ) { append(draft) }
                if let citationDraft = memoryCitationDraft(
                    citations: answer.memoryCitations,
                    sectionID: sectionID,
                    sourceID: answer.id,
                    theme: theme
                ) {
                    append(citationDraft)
                }
            }
            for image in turn.generatedImages {
                let label = CodexTranscriptImageSource.localFilePath(image.source)
                    .map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? "Generated image"
                append(ItemDraft(
                    id: "\(sectionID):generated-image:\(image.id)",
                    fingerprint: "generated-image:\(image.source)",
                    agentChips: [.init(
                        id: image.id,
                        label: label,
                        status: .done,
                        threadID: nil,
                        taskSummary: image.source,
                        latestUpdate: image.revisedPrompt,
                        attachmentKind: .image,
                        imagePreviewSize: 360,
                        imagePreviewAspectRatio: imageAspectRatio(for: image.source)
                    )],
                    accessibilityLabel: "Generated image",
                    maxWidthKind: .card,
                    intrinsicContentWidth: 360,
                    bottomSpacing: CodexTranscriptColumnMetrics.interactiveBottomSpacing
                ))
            }
            for failure in turn.imageGenerationFailures {
                append(ItemDraft(
                    id: "\(sectionID):generated-image-failure:\(failure.id)",
                    fingerprint: "generated-image-failure:\(failure.type):\(failure.message)",
                    textRole: .notice,
                    preparedText: Self.preparePlain(
                        failure.message,
                        font: theme.captionFont,
                        color: theme.danger,
                        theme: theme
                    ),
                    copyText: failure.message,
                    accessibilityLabel: failure.message,
                    maxWidthKind: .card,
                    bottomSpacing: CodexTranscriptColumnMetrics.interactiveBottomSpacing
                ))
            }
            if let answer = turn.finalAnswer, !answer.text.isEmpty {
                if turn.presentationStyle != .realtimeVoice {
                    append(timestampDraft(
                        id: "\(sectionID):final-timestamp",
                        date: answer.sentAt,
                        trailing: false,
                        kind: .finalAnswer,
                        isTurnStreaming: turnIsStreaming,
                        copyText: answer.text
                    ))
                }
            }
            if turn.presentationStyle == .realtimeVoice,
               case .working = turn.status,
               let tail = turn.liveTail?.trimmingCharacters(in: .whitespacesAndNewlines),
               !tail.isEmpty {
                append(ItemDraft(
                    id: "\(sectionID):voice-live-tail",
                    fingerprint: "voice-tail:\(tail)",
                    textRole: .liveTail,
                    preparedText: Self.preparePlain(
                        tail,
                        font: theme.captionFont,
                        color: theme.textTertiary,
                        theme: theme
                    ),
                    accessibilityLabel: tail,
                    maxWidthKind: .card,
                    fixedHeight: 28
                ))
            }
            itemIDsBySection[sectionID] = sectionItems
            var cachedItems: [CodexTranscriptRenderItemID: CodexTranscriptRenderItem] = [:]
            cachedItems.reserveCapacity(sectionItems.count)
            for id in sectionItems {
                cachedItems[id] = itemsByID[id]
            }
            cachedSectionsByTurnID[turn.id] = CachedTurnSection(
                sectionID: sectionID,
                itemIDs: sectionItems,
                itemsByID: cachedItems
            )
        }
        cachedSectionsByTurnID = cachedSectionsByTurnID.filter { liveTurnIDs.contains($0.key) }

        revisionByID = revisionByID.filter { liveIDs.contains($0.key) }
        heightByKey = heightByKey.filter { key, _ in
            liveIDs.contains(key.id) && revisionByID[key.id]?.revision == key.revision
        }
        let liveSourcePrefixes = Set(itemsByID.keys.map { id in
            id.rawValue.components(separatedBy: ":block:").first ?? id.rawValue
        })
        previousBlocksBySourceID = previousBlocksBySourceID.filter { liveSourcePrefixes.contains($0.key) }
        sourceTextBySourceID = sourceTextBySourceID.filter { liveSourcePrefixes.contains($0.key) }
        var orderedItemIDs: [CodexTranscriptRenderItemID] = []
        orderedItemIDs.reserveCapacity(itemsByID.count)
        for sectionID in sections {
            orderedItemIDs.append(contentsOf: itemIDsBySection[sectionID] ?? [])
        }
        projectionCount += 1
        let elapsed = startedAt.duration(to: .now)
        let milliseconds = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        let diagnostics = CodexTranscriptRenderDiagnostics(
            projectionCount: projectionCount,
            projectedItemCount: itemsByID.count,
            changedItemCount: changedIDs.count,
            heightCacheHitCount: cacheHits,
            heightCacheMissCount: cacheMisses,
            preparedTextCacheHitCount: preparedTextCacheHits,
            preparedTextCacheMissCount: preparedTextCacheMisses,
            markdownProjectionCount: markdownProjections,
            projectionDurationMilliseconds: milliseconds
        )
        return CodexTranscriptRenderSnapshot(
            threadID: presentation.threadID,
            sectionIDs: sections,
            itemIDsBySection: itemIDsBySection,
            orderedItemIDs: orderedItemIDs,
            itemsByID: itemsByID,
            changedItemIDs: changedIDs,
            diagnostics: diagnostics
        )
    }

    private func projectBlocks(
        _ text: String,
        streaming: Bool,
        sourceID: String
    ) -> [CodexBlock] {
        if sourceTextBySourceID[sourceID] == text,
           let previous = previousBlocksBySourceID[sourceID] {
            return previous
        }
        let blocks = CodexBlockProjector.project(
            text,
            previous: previousBlocksBySourceID[sourceID],
            streaming: streaming,
            cacheNamespace: sourceID
        )
        sourceTextBySourceID[sourceID] = text
        previousBlocksBySourceID[sourceID] = blocks
        return blocks
    }
}

private extension CodexTranscriptRenderProjector {
    struct ItemDraft {
        var id: String
        var fingerprint: String
        var textRole: CodexTranscriptTextRole?
        var preparedText: CodexPreparedTranscriptText?
        var workHeader: CodexTranscriptWorkHeaderRender?
        var workRow: CodexTranscriptWorkRowRender?
        var agentChips: [CodexTranscriptAgentChipRender]
        var diffPanel: CodexTranscriptDiffPanelRender?
        var turnDiff: CodexTranscriptTurnDiffRender?
        var code: CodexTranscriptCodeRender?
        var footer: CodexTranscriptFooterRender?
        var productTool: CodexProductToolCallV2?
        var renderNode: CodexTranscriptRenderNodeV2?
        var directive: CodexTranscriptDirectiveRender?
        var approval: CodexTranscriptApprovalRender?
        var action: CodexTranscriptRenderAction?
        var copyPayload: CodexTranscriptCopyPayload?
        var editUserText: String?
        var accessibilityLabel: String
        var indentation: CGFloat
        var isTrailingAligned: Bool
        var maxWidthKind: CodexTranscriptContentWidthPolicy
        var fixedHeight: CGFloat?
        var intrinsicContentWidth: CGFloat?
        var bottomSpacing: CGFloat
        var isScrollableOutput: Bool

        init(
            id: String,
            fingerprint: String,
            textRole: CodexTranscriptTextRole? = nil,
            preparedText: CodexPreparedTranscriptText? = nil,
            workHeader: CodexTranscriptWorkHeaderRender? = nil,
            workRow: CodexTranscriptWorkRowRender? = nil,
            agentChips: [CodexTranscriptAgentChipRender] = [],
            diffPanel: CodexTranscriptDiffPanelRender? = nil,
            turnDiff: CodexTranscriptTurnDiffRender? = nil,
            code: CodexTranscriptCodeRender? = nil,
            footer: CodexTranscriptFooterRender? = nil,
            productTool: CodexProductToolCallV2? = nil,
            renderNode: CodexTranscriptRenderNodeV2? = nil,
            directive: CodexTranscriptDirectiveRender? = nil,
            approval: CodexTranscriptApprovalRender? = nil,
            action: CodexTranscriptRenderAction? = nil,
            copyText: String? = nil,
            copyPayload: CodexTranscriptCopyPayload? = nil,
            editUserText: String? = nil,
            accessibilityLabel: String,
            indentation: CGFloat = 0,
            isTrailingAligned: Bool = false,
            maxWidthKind: CodexTranscriptContentWidthPolicy = .full,
            fixedHeight: CGFloat? = nil,
            intrinsicContentWidth: CGFloat? = nil,
            bottomSpacing: CGFloat = 0,
            isScrollableOutput: Bool = false
        ) {
            self.id = id
            self.fingerprint = fingerprint
            self.textRole = textRole
            self.preparedText = preparedText
            self.workHeader = workHeader
            self.workRow = workRow
            self.agentChips = agentChips
            self.diffPanel = diffPanel
            self.turnDiff = turnDiff
            self.code = code
            self.footer = footer
            self.productTool = productTool
            self.renderNode = renderNode
            self.directive = directive
            self.approval = approval
            self.action = action
            self.copyPayload = copyPayload
                ?? copyText.map(CodexTranscriptCopyPayload.text)
            self.editUserText = editUserText
            self.accessibilityLabel = accessibilityLabel
            self.indentation = indentation
            self.isTrailingAligned = isTrailingAligned
            self.maxWidthKind = maxWidthKind
            self.fixedHeight = fixedHeight
            self.intrinsicContentWidth = intrinsicContentWidth
            self.bottomSpacing = bottomSpacing
            self.isScrollableOutput = isScrollableOutput
        }

        func maxWidth(_ contentWidth: CGFloat, _ theme: CodexTranscriptAppKitTheme) -> CGFloat {
            switch maxWidthKind {
            case .full: contentWidth
            case .card: min(contentWidth, theme.cardMaxWidth)
            case .user: min(contentWidth * 0.77, theme.userBubbleMaxWidth)
            }
        }
    }

    func contentDrafts(
        text: String,
        streaming: Bool,
        sourceID: String,
        role: CodexTranscriptTextRole,
        theme: CodexTranscriptAppKitTheme,
        cacheHits: inout Int,
        cacheMisses: inout Int,
        markdownProjections: inout Int
    ) -> [ItemDraft] {
        let partitions = CodexInlineDirectiveParser.split(text: text)
        guard partitions.contains(where: { $0.directive != nil }) else {
            return ordinaryMessageDrafts(
                text: text, streaming: streaming, sourceID: sourceID, role: role, theme: theme,
                cacheHits: &cacheHits, cacheMisses: &cacheMisses,
                markdownProjections: &markdownProjections
            )
        }

        var result: [ItemDraft] = []
        var directiveIndex = 0
        for (partitionIndex, partition) in partitions.enumerated() {
            if let directive = partition.directive {
                result.append(directiveDraft(
                    directive, raw: partition.text,
                    itemID: "\(sourceID):directive:\(directiveIndex)", theme: theme,
                    cacheHits: &cacheHits, cacheMisses: &cacheMisses
                ))
                directiveIndex += 1
            } else if !partition.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(contentsOf: ordinaryMessageDrafts(
                    text: partition.text, streaming: streaming,
                    sourceID: "\(sourceID):segment:\(partitionIndex)", role: role, theme: theme,
                    cacheHits: &cacheHits, cacheMisses: &cacheMisses,
                    markdownProjections: &markdownProjections
                ))
            }
        }
        return result
    }

    func ordinaryMessageDrafts(
        text: String,
        streaming: Bool,
        sourceID: String,
        role: CodexTranscriptTextRole,
        theme: CodexTranscriptAppKitTheme,
        cacheHits: inout Int,
        cacheMisses: inout Int,
        markdownProjections: inout Int
    ) -> [ItemDraft] {
        let blocks = projectBlocks(text, streaming: streaming, sourceID: sourceID)
        markdownProjections += 1
        if blocks.count == 1, let block = blocks.first {
            return [draft(
                block: block,
                itemID: block.isCodeV2 ? nil : "\(sourceID):selection-surface:0",
                role: role, theme: theme, cacheHits: &cacheHits, cacheMisses: &cacheMisses
            )]
        }
        return messageDrafts(
            blocks: blocks, sourceID: sourceID, role: role, theme: theme,
            cacheHits: &cacheHits, cacheMisses: &cacheMisses
        )
    }

    func directiveDraft(
        _ directive: CodexInlineDirective,
        raw: String,
        itemID: String,
        theme: CodexTranscriptAppKitTheme,
        cacheHits: inout Int,
        cacheMisses: inout Int
    ) -> ItemDraft {
        let attributes = directive.attributes
        let render: CodexTranscriptDirectiveRender
        let action: CodexTranscriptRenderAction?
        let label: String
        var preparedText: CodexPreparedTranscriptText?
        var fixedHeight: CGFloat? = CodexTranscriptColumnMetrics.actionCardHeight

        switch directive.name {
        case "created-thread":
            let clientID = attributes["clientThreadId"]?.replacingOccurrences(of: "client-new-thread:", with: "")
            let threadID = attributes["threadId"] ?? attributes["threadID"]
            let pendingID = attributes["pendingWorktreeId"] ?? attributes["pendingWorktreeID"] ?? clientID
            render = .init(kind: .createdThread(threadID: threadID, pendingWorktreeID: pendingID), raw: raw)
            action = pendingID == nil
                ? threadID.map { .openThread(.init(threadID: $0)) }
                : nil
            label = (pendingID == nil ? "Chat created" : "Worktree chat queued")
                + " · \(Self.shortIdentifier(threadID ?? pendingID ?? "pending"))"
        case "git-stage", "git-commit", "git-create-branch", "git-push":
            let verb = String(directive.name.dropFirst(4))
            let branch = attributes["branch"]
            render = .init(kind: .gitAction(verb: verb, branch: branch, cwd: attributes["cwd"]), raw: raw)
            action = nil
            label = switch verb {
            case "stage": "Staged changes"
            case "commit": "Committed"
            case "create-branch": "Created branch \(branch ?? "")".trimmingCharacters(in: .whitespaces)
            case "push": "Pushed \(branch ?? "")".trimmingCharacters(in: .whitespaces)
            default: "Git · \(verb)"
            }
        case "git-create-pr":
            let url = attributes["url"] ?? ""
            let branch = attributes["branch"]
            let isDraft = attributes["isDraft"] == "true"
            render = .init(kind: .pullRequest(url: url, branch: branch, isDraft: isDraft), raw: raw)
            action = url.isEmpty ? nil : .openURL(url)
            label = "PR" + (branch.map { " · \($0)" } ?? "") + (isDraft ? " · draft" : "")
        case "code-comment":
            let title = attributes["title"] ?? "Code comment"
            let body = attributes["body"] ?? ""
            let file = attributes["file"] ?? ""
            let start = attributes["start"].flatMap(Int.init)
            let end = attributes["end"].flatMap(Int.init)
            let priority = attributes["priority"].flatMap(Int.init)
            render = .init(kind: .codeComment(
                title: title, body: body, file: file, start: start, end: end, priority: priority
            ), raw: raw)
            action = file.isEmpty ? nil : .openFile(path: file, line: start)
            label = title
            preparedText = cachedPreparedText(
                content: body, style: "directive-code-comment", theme: theme,
                cacheHits: &cacheHits, cacheMisses: &cacheMisses
            ) { Self.prepareMarkdown(body, font: theme.bodyFont, color: theme.textSecondary, theme: theme) }
            fixedHeight = nil
        default:
            render = .init(kind: .unknown(name: directive.name), raw: raw)
            action = nil
            label = "<\(directive.name)>"
        }
        return ItemDraft(
            id: itemID, fingerprint: "directive:\(raw)", preparedText: preparedText,
            directive: render, action: action, copyText: raw, accessibilityLabel: label,
            maxWidthKind: .card, fixedHeight: fixedHeight
        )
    }

    static func shortIdentifier(_ value: String) -> String {
        let tail = value.split(separator: "-").last.map(String.init) ?? value
        return String(tail.prefix(8))
    }

    func messageDrafts(
        blocks: [CodexBlock],
        sourceID: String,
        role: CodexTranscriptTextRole,
        theme: CodexTranscriptAppKitTheme,
        cacheHits: inout Int,
        cacheMisses: inout Int
    ) -> [ItemDraft] {
        var drafts: [ItemDraft] = []
        var textRun: [CodexBlock] = []
        var textRunIndex = 0

        for block in blocks {
            if case .code = block {
                if !textRun.isEmpty {
                    drafts.append(textRunDraft(
                        blocks: textRun,
                        sourceID: sourceID,
                        runIndex: textRunIndex,
                        role: role,
                        theme: theme,
                        cacheHits: &cacheHits,
                        cacheMisses: &cacheMisses
                    ))
                    textRun.removeAll(keepingCapacity: true)
                    textRunIndex += 1
                }
                drafts.append(draft(
                    block: block,
                    role: role,
                    theme: theme,
                    cacheHits: &cacheHits,
                    cacheMisses: &cacheMisses
                ))
            } else if case .math = block {
                if !textRun.isEmpty {
                    drafts.append(textRunDraft(
                        blocks: textRun,
                        sourceID: sourceID,
                        runIndex: textRunIndex,
                        role: role,
                        theme: theme,
                        cacheHits: &cacheHits,
                        cacheMisses: &cacheMisses
                    ))
                    textRun.removeAll(keepingCapacity: true)
                    textRunIndex += 1
                }
                drafts.append(draft(
                    block: block,
                    role: role,
                    theme: theme,
                    cacheHits: &cacheHits,
                    cacheMisses: &cacheMisses
                ))
            } else if case .mermaid = block {
                if !textRun.isEmpty {
                    drafts.append(textRunDraft(
                        blocks: textRun,
                        sourceID: sourceID,
                        runIndex: textRunIndex,
                        role: role,
                        theme: theme,
                        cacheHits: &cacheHits,
                        cacheMisses: &cacheMisses
                    ))
                    textRun.removeAll(keepingCapacity: true)
                    textRunIndex += 1
                }
                drafts.append(draft(
                    block: block,
                    role: role,
                    theme: theme,
                    cacheHits: &cacheHits,
                    cacheMisses: &cacheMisses
                ))
            } else {
                textRun.append(block)
            }
        }

        if !textRun.isEmpty {
            drafts.append(textRunDraft(
                blocks: textRun,
                sourceID: sourceID,
                runIndex: textRunIndex,
                role: role,
                theme: theme,
                cacheHits: &cacheHits,
                cacheMisses: &cacheMisses
            ))
        }
        return drafts
    }

    func textRunDraft(
        blocks: [CodexBlock],
        sourceID: String,
        runIndex: Int,
        role: CodexTranscriptTextRole,
        theme: CodexTranscriptAppKitTheme,
        cacheHits: inout Int,
        cacheMisses: inout Int
    ) -> ItemDraft {
        let runFingerprint = blocks.map { "\($0.id):\($0.contentDigest)" }.joined(separator: "|")
        let prepared: CodexPreparedTranscriptText
        if blocks.count == 1, let block = blocks.first {
            prepared = cachedPreparedText(
                content: block.contentDigest,
                style: "block-\(role)-\(block.id)",
                theme: theme,
                cacheHits: &cacheHits,
                cacheMisses: &cacheMisses
            ) {
                Self.prepare(block: block, role: role, theme: theme)
            }
        } else {
            var preparedBlocks: [NSAttributedString] = []
            preparedBlocks.reserveCapacity(blocks.count)
            for block in blocks {
                let blockText = cachedPreparedText(
                    content: block.contentDigest,
                    style: "block-\(role)-\(block.id)",
                    theme: theme,
                    cacheHits: &cacheHits,
                    cacheMisses: &cacheMisses
                ) {
                    Self.prepare(block: block, role: role, theme: theme)
                }
                preparedBlocks.append(blockText.attributedString)
            }
            prepared = cachedPreparedText(
                content: runFingerprint,
                style: "selection-surface-\(role)-\(sourceID)-\(runIndex)",
                theme: theme,
                cacheHits: &cacheHits,
                cacheMisses: &cacheMisses
            ) {
                Self.combine(preparedBlocks, role: role, theme: theme)
            }
        }
        let text = prepared.attributedString.string
        return ItemDraft(
            id: "\(sourceID):selection-surface:\(runIndex)",
            fingerprint: "selection-surface:\(role):\(runFingerprint)",
            textRole: role,
            preparedText: prepared,
            copyText: text,
            accessibilityLabel: "\(role == .finalAnswer ? "Assistant" : "Commentary"): \(text)",
            maxWidthKind: .card
        )
    }

    func draft(
        block: CodexBlock,
        itemID: String? = nil,
        role: CodexTranscriptTextRole,
        theme: CodexTranscriptAppKitTheme,
        cacheHits: inout Int,
        cacheMisses: inout Int
    ) -> ItemDraft {
        switch block {
        case .code(let id, let language, let code, let complete):
            let displayCode = code.count > 40_000 ? Self.bounded(code, limit: 40_000) : code
            let prepared = cachedPreparedText(
                content: displayCode,
                style: "code-\(language ?? "plain")-\(complete ? "stable" : "streaming")",
                theme: theme,
                cacheHits: &cacheHits,
                cacheMisses: &cacheMisses
            ) { [codeHighlighter] in
                if complete,
                   code.count <= 40_000,
                   let highlighted = codeHighlighter.highlight(code, language: language, theme: theme) {
                    return CodexPreparedTranscriptText(highlighted)
                }
                return Self.preparePlain(displayCode, font: theme.codeFont, color: theme.codeText, theme: theme)
            }
            return ItemDraft(
                id: itemID ?? id,
                fingerprint: "code:\(complete):\(language ?? ""):\(code)",
                preparedText: prepared,
                code: CodexTranscriptCodeRender(language: language, code: displayCode),
                copyText: code,
                accessibilityLabel: "Code block \(language ?? "code"): \(code)",
                maxWidthKind: .card
            )
        case .math(let id, let latex, let display):
            let bounded = Self.bounded(latex, limit: 40_000)
            let prepared = cachedPreparedText(
                content: bounded,
                style: "math",
                theme: theme,
                cacheHits: &cacheHits,
                cacheMisses: &cacheMisses
            ) {
                Self.preparePlain(bounded, font: theme.codeFont, color: theme.textPrimary, theme: theme)
            }
            return ItemDraft(
                id: itemID ?? id,
                fingerprint: "math:\(display):\(bounded)",
                textRole: role,
                preparedText: prepared,
                code: .init(language: "math", code: bounded),
                copyText: latex,
                accessibilityLabel: "Mathematical expression: \(bounded)",
                maxWidthKind: .card
            )
        case .mermaid(let id, let diagram, let complete):
            let bounded = Self.bounded(diagram, limit: 40_000)
            let prepared = cachedPreparedText(
                content: bounded,
                style: "mermaid-\(complete)",
                theme: theme,
                cacheHits: &cacheHits,
                cacheMisses: &cacheMisses
            ) {
                Self.preparePlain(bounded, font: theme.codeFont, color: theme.textPrimary, theme: theme)
            }
            return ItemDraft(
                id: itemID ?? id,
                fingerprint: "mermaid:\(complete):\(bounded)",
                textRole: role,
                preparedText: prepared,
                code: .init(language: "mermaid", code: bounded),
                copyText: diagram,
                accessibilityLabel: "Mermaid diagram: \(bounded)",
                maxWidthKind: .card
            )
        default:
            let prepared = cachedPreparedText(
                content: block.contentDigest,
                style: "block-\(role)-\(block.id)",
                theme: theme,
                cacheHits: &cacheHits,
                cacheMisses: &cacheMisses
            ) {
                Self.prepare(block: block, role: role, theme: theme)
            }
            return ItemDraft(
                id: itemID ?? block.id,
                fingerprint: "text:\(role):\(block.contentDigest)",
                textRole: role,
                preparedText: prepared,
                copyText: prepared.attributedString.string,
                accessibilityLabel: "\(role == .finalAnswer ? "Assistant" : "Commentary"): \(prepared.attributedString.string)",
                maxWidthKind: .card
            )
        }
    }

    func timestampDraft(
        id: String,
        date: Date?,
        trailing: Bool,
        kind: CodexTranscriptFooterRender.Kind,
        isTurnStreaming: Bool,
        copyText: String
    ) -> ItemDraft {
        let label = date?.formatted(date: .omitted, time: .shortened) ?? ""
        return ItemDraft(
            id: id,
            fingerprint: "timestamp:\(label):streaming:\(isTurnStreaming)",
            textRole: .timestamp,
            footer: .init(kind: kind, timestamp: label, isTurnStreaming: isTurnStreaming),
            copyText: copyText,
            accessibilityLabel: label.isEmpty ? "Message actions" : "Presented at \(label)",
            isTrailingAligned: trailing,
            maxWidthKind: trailing ? .user : .card,
            fixedHeight: CodexTranscriptColumnMetrics.footerHeight
        )
    }

    func userMessageDrafts(
        _ user: CodexUserMessageV2,
        sectionID: String,
        contentWidth: CGFloat,
        turnIsStreaming: Bool,
        hidesTimestamp: Bool = false,
        theme: CodexTranscriptAppKitTheme,
        cacheHits: inout Int,
        cacheMisses: inout Int
    ) -> [ItemDraft] {
        // Trailing whitespace/newlines would measure as phantom empty lines
        // and inflate the bubble; display trimmed, keep the raw text for copy.
        let displayText = user.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleUserText = displayText.isEmpty && !user.referencedFiles.isEmpty
            ? "Attached files"
            : displayText
        let prepared = cachedPreparedText(
            content: user.displayText,
            style: "user-plain",
            theme: theme,
            cacheHits: &cacheHits,
            cacheMisses: &cacheMisses
        ) {
            Self.prepareUserMessage(
                user,
                text: visibleUserText,
                font: theme.bodyFont,
                color: theme.textPrimary,
                theme: theme
            )
        }
        let userMaxWidth = min(contentWidth * 0.77, theme.userBubbleMaxWidth)
        let horizontalPadding = CodexTranscriptColumnMetrics.userBubbleHorizontalPadding * 2
        let textBounds = prepared.attributedString.boundingRect(
            with: NSSize(
                width: max(1, userMaxWidth - horizontalPadding),
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        var drafts: [ItemDraft] = []
        if let source = user.delegationSource {
            let row = CodexTranscriptWorkRowRender(
                kind: .other,
                label: "Sent by Codex from another chat",
                status: .completed,
                systemImage: "bubble.left.and.bubble.right",
                style: .inlineActivity,
                durationMs: nil,
                isExpanded: false,
                hasDetail: false,
                isSubagentLink: false
            )
            drafts.append(ItemDraft(
                id: "\(sectionID):user:\(user.id):delegation-source",
                fingerprint: "delegation-source:\(source)",
                workRow: row,
                action: .openThread(source),
                accessibilityLabel: "Sent by Codex from another chat. Open source chat",
                isTrailingAligned: true,
                maxWidthKind: .user,
                fixedHeight: CodexTranscriptColumnMetrics.workRowHeight,
                bottomSpacing: 2
            ))
        }
        if !user.responseAnnotations.isEmpty {
            let count = user.responseAnnotations.count
            let summary = user.responseAnnotations.enumerated().map { index, annotation in
                var lines = ["\(index + 1). Selected text: \(annotation.text)"]
                if let comment = annotation.annotation {
                    lines.append("User comment: \(comment)")
                }
                return lines.joined(separator: "\n")
            }.joined(separator: "\n\n")
            let chip = CodexTranscriptAgentChipRender(
                id: "\(user.id):response-annotations",
                label: count == 1 ? "1 annotation" : "\(count) annotations",
                systemImage: "text.bubble",
                status: .done,
                threadID: nil,
                taskSummary: summary
            )
            drafts.append(ItemDraft(
                id: "\(sectionID):user:\(user.id):response-annotations",
                fingerprint: "response-annotations:\(user.responseAnnotations)",
                agentChips: [chip],
                accessibilityLabel: chip.label,
                isTrailingAligned: true,
                maxWidthKind: .user,
                intrinsicContentWidth: min(
                    userMaxWidth,
                    ceil((chip.label as NSString).size(
                        withAttributes: [.font: theme.captionFont]
                    ).width) + 34
                ),
                bottomSpacing: CodexTranscriptColumnMetrics.interactiveBottomSpacing
            ))
        }
        if !user.referencedFiles.isEmpty {
            let attachmentChips = user.referencedFiles.map {
                CodexTranscriptAgentChipRender(
                    id: "\(user.id):attachment:\($0.id)",
                    label: $0.displayName,
                    status: .done,
                    threadID: nil,
                    taskSummary: $0.path,
                    latestUpdate: nil,
                    attachmentKind: $0.kind
                )
            }
            let attachmentWidth = min(
                userMaxWidth,
                attachmentChips.reduce(CGFloat.zero) { total, chip in
                    let width = chip.attachmentKind == .image
                        ? chip.imagePreviewSize
                        : ceil((chip.label as NSString).size(
                            withAttributes: [.font: theme.captionFont]
                        ).width) + 34
                    return total + width
                } + CGFloat(max(0, attachmentChips.count - 1) * 6)
            )
            drafts.append(ItemDraft(
                id: "\(sectionID):user:\(user.id):attachments",
                fingerprint: "attachments:\(user.referencedFiles.map(\.path).joined(separator: "|"))",
                agentChips: attachmentChips,
                accessibilityLabel: "Attached files: \(user.referencedFiles.map(\.displayName).joined(separator: ", "))",
                isTrailingAligned: true,
                maxWidthKind: .user,
                intrinsicContentWidth: attachmentWidth,
                bottomSpacing: CodexTranscriptColumnMetrics.interactiveBottomSpacing
            ))
        }
        if !user.attachments.isEmpty {
            let chips = user.attachments.map { attachment in
                CodexTranscriptAgentChipRender(
                    id: "\(user.id):attachment:\(attachment.id)",
                    label: attachment.label,
                    status: .done,
                    threadID: nil,
                    taskSummary: attachment.value,
                    latestUpdate: attachment.detail,
                    attachmentKind: attachment.kind == .image ? .image : .file
                )
            }
            drafts.append(ItemDraft(
                id: "\(sectionID):user:\(user.id):typed-attachments",
                fingerprint: "typed-attachments:\(user.attachments)",
                agentChips: chips,
                accessibilityLabel: "Attached input: \(user.attachments.map(\.label).joined(separator: ", "))",
                isTrailingAligned: true,
                maxWidthKind: .user,
                bottomSpacing: CodexTranscriptColumnMetrics.interactiveBottomSpacing
            ))
        }
        if !user.context.isEmpty {
            let chips = user.context.map { context in
                CodexTranscriptAgentChipRender(
                    id: "\(user.id):context:\(context.id)",
                    label: context.kind == .untrusted ? "Untrusted context" : "Context",
                    status: .done,
                    threadID: nil,
                    taskSummary: context.value,
                    latestUpdate: context.id,
                    attachmentKind: nil
                )
            }
            drafts.append(ItemDraft(
                id: "\(sectionID):user:\(user.id):context",
                fingerprint: "context:\(user.context)",
                agentChips: chips,
                accessibilityLabel: "Additional context attached",
                isTrailingAligned: true,
                maxWidthKind: .user,
                bottomSpacing: CodexTranscriptColumnMetrics.interactiveBottomSpacing
            ))
        }
        if !visibleUserText.isEmpty {
            drafts.append(ItemDraft(
                id: "\(sectionID):user:\(user.id)",
                fingerprint: "user:\(user.rawText):\(user.isOptimistic)",
                textRole: .user,
                preparedText: prepared,
                copyText: user.text.isEmpty ? user.displayText : user.text,
                editUserText: user.delegationSource == nil ? user.rawText : nil,
                accessibilityLabel: "You: \(visibleUserText)",
                isTrailingAligned: true,
                maxWidthKind: .user,
                intrinsicContentWidth: min(userMaxWidth, ceil(textBounds.width) + horizontalPadding)
            ))
        }
        if !hidesTimestamp {
            drafts.append(timestampDraft(
                id: "\(sectionID):user-timestamp:\(user.id)",
                date: user.sentAt,
                trailing: true,
                kind: .user,
                isTurnStreaming: turnIsStreaming,
                copyText: user.text.isEmpty ? user.displayText : user.text
            ))
        }
        return drafts
    }

    func memoryCitationDraft(
        citations: [CodexMemoryCitationV2],
        sectionID: String,
        sourceID: String,
        theme _: CodexTranscriptAppKitTheme
    ) -> ItemDraft? {
        guard !citations.isEmpty else { return nil }
        let chips = citations.map { citation in
            CodexTranscriptAgentChipRender(
                id: "\(sourceID):memory-citation:\(citation.id)",
                label: "\(citation.path):\(citation.lineStart)",
                status: .done,
                threadID: nil,
                taskSummary: citation.path,
                latestUpdate: citation.note,
                attachmentKind: .file
            )
        }
        let labels = citations.map { "\($0.path):\($0.lineStart)-\($0.lineEnd)" }
        return ItemDraft(
            id: "\(sectionID):memory-citations:\(sourceID)",
            fingerprint: "memory-citations:\(citations)",
            agentChips: chips,
            action: citations.first.map { .openFile(path: $0.path, line: $0.lineStart) },
            copyText: labels.joined(separator: "\n"),
            accessibilityLabel: "Memory citations: \(labels.joined(separator: ", "))",
            isTrailingAligned: false,
            maxWidthKind: .card,
            bottomSpacing: CodexTranscriptColumnMetrics.interactiveBottomSpacing
        )
    }

    func cachedPreparedText(
        content: String,
        style: String,
        theme: CodexTranscriptAppKitTheme,
        cacheFingerprint: UInt64? = nil,
        cacheHits: inout Int,
        cacheMisses: inout Int,
        make: () -> CodexPreparedTranscriptText
    ) -> CodexPreparedTranscriptText {
        let contentKey = cacheFingerprint.map { String($0, radix: 16) }
            ?? CodexBlockDigest.digest(content)
        let key = theme.fingerprint + ":" + style + ":" + contentKey
        if style == "diff-file" {
            if preparedDiffText?.key == key, let cached = preparedDiffText?.text {
                cacheHits += 1
                return cached
            }
            let prepared = make()
            preparedDiffText = (key, prepared)
            cacheMisses += 1
            return prepared
        }
        if let cached = preparedTextByKey[key] {
            cacheHits += 1
            return cached
        }
        let prepared = make()
        preparedTextByKey[key] = prepared
        preparedTextInsertionOrder.append(key)
        cacheMisses += 1
        if preparedTextInsertionOrder.count > 8_192 {
            let expired = Array(preparedTextInsertionOrder.prefix(1_024))
            preparedTextInsertionOrder.removeFirst(1_024)
            for key in expired { preparedTextByKey.removeValue(forKey: key) }
        }
        return prepared
    }

    static func measure(
        draft: ItemDraft,
        width: CGFloat,
        theme: CodexTranscriptAppKitTheme
    ) -> CGFloat {
        if let fixedHeight = draft.fixedHeight { return fixedHeight + draft.bottomSpacing }
        if !draft.agentChips.isEmpty {
            return agentChipClusterHeight(
                draft.agentChips,
                width: max(80, width - draft.indentation),
                font: theme.captionFont
            ) + draft.bottomSpacing
        }
        if let code = draft.code {
            let text = draft.preparedText?.attributedString
                ?? preparePlain(code.code, font: theme.codeFont, color: theme.codeText, theme: theme).attributedString
            let bounds = text.boundingRect(
                with: NSSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            let height = max(76, ceil(bounds.height) + 52)
            let measured = draft.isScrollableOutput
                ? min(CodexTranscriptColumnMetrics.scrollableOutputMaxHeight, height)
                : height
            return measured + draft.bottomSpacing
        }
        let horizontalPadding: CGFloat = draft.textRole == .user
            ? CodexTranscriptColumnMetrics.userBubbleHorizontalPadding * 2
            : (draft.textRole == .expandedOutput ? 24 : 0)
        if let text = draft.preparedText?.attributedString {
            let measurementWidth = draft.textRole == .expandedOutput
                ? 1_000_000
                : max(80, width - horizontalPadding - draft.indentation)
            let bounds = text.boundingRect(
                with: NSSize(width: measurementWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            let isCodeComment: Bool
            if case .codeComment = draft.directive?.kind { isCodeComment = true } else { isCodeComment = false }
            let verticalPadding: CGFloat = isCodeComment
                ? 64
                : (draft.textRole == .user
                    ? CodexTranscriptColumnMetrics.userBubbleVerticalPadding * 2
                    : (draft.textRole == .expandedOutput
                        ? 16
                        : CodexTranscriptColumnMetrics.itemGap + 2))
            let height = max(18, ceil(bounds.height) + verticalPadding)
            let measured = draft.isScrollableOutput
                ? min(CodexTranscriptColumnMetrics.scrollableOutputMaxHeight, height)
                : height
            return measured + draft.bottomSpacing
        }
        return 36 + draft.bottomSpacing
    }

    static func agentChipClusterHeight(
        _ chips: [CodexTranscriptAgentChipRender],
        width: CGFloat,
        font: NSFont
    ) -> CGFloat {
        let height = max(26, chips.compactMap {
            $0.attachmentKind == .image ? $0.imagePreviewHeight : nil
        }.max() ?? 0)
        let gap: CGFloat = 6
        var x: CGFloat = 0
        var rows: CGFloat = 1
        for chip in chips {
            let isAttachmentImage = chip.attachmentKind == .image
            let title = chip.threadID == nil
                ? chip.label
                : "\(chip.label) · \(chip.status.transcriptLabel.lowercased())"
            let labelWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
            let chipWidth = isAttachmentImage
                ? chip.imagePreviewSize
                : min(width, max(74, labelWidth + 28))
            if x > 0, x + chipWidth > width {
                rows += 1
                x = 0
            }
            x += chipWidth + gap
        }
        return rows * height + max(0, rows - 1) * gap
    }

    static func agentChipLabel(_ agent: CodexCollabAgentRowV2) -> String {
        guard let raw = agent.agentNames.first, !raw.isEmpty else { return "Agent" }
        let leaf = raw.split(separator: "/").last.map(String.init) ?? raw
        return leaf.capitalized
    }

    private func imageAspectRatio(for source: String) -> CGFloat {
        if let cached = imageAspectRatioBySource[source] { return cached }
        let ratio = CodexTranscriptImageSource.aspectRatio(source) ?? 1
        imageAspectRatioBySource[source] = ratio
        return ratio
    }

    static func agentClusterAccessibilityLabel(
        _ chips: [CodexTranscriptAgentChipRender]
    ) -> String {
        chips.map { chip in
            "\(chip.label), \(chip.status.transcriptLabel.lowercased())"
        }.joined(separator: "; ")
    }

    static func prepare(block: CodexBlock, role: CodexTranscriptTextRole, theme: CodexTranscriptAppKitTheme) -> CodexPreparedTranscriptText {
        switch block {
        case .prose(_, let text, _), .htmlFallback(_, let text):
            return prepareMarkdown(text, font: theme.bodyFont, color: color(for: role, theme: theme), theme: theme)
        case .heading(_, let level, let text, _):
            let size: CGFloat = switch level { case 1: 20; case 2: 17; case 3: 15; default: 14 }
            let font = NSFontManager.shared.convert(.systemFont(ofSize: size), toHaveTrait: .boldFontMask)
            return preparePlain(text, font: font, color: theme.textPrimary, theme: theme)
        case .list(_, let ordered, let items):
            let result = NSMutableAttributedString()
            var counters: [Int: Int] = [:]
            for item in items {
                counters.keys.filter { $0 > item.depth }.forEach { counters.removeValue(forKey: $0) }
                counters[item.depth, default: 0] += 1
                let marker: String
                if item.isTask {
                    marker = (item.isCompleted ? "☑" : "☐") + "\t"
                } else {
                    marker = ordered ? "\(counters[item.depth]!).\t" : "•\t"
                }
                let style = NSMutableParagraphStyle()
                style.lineSpacing = theme.lineSpacing
                style.paragraphSpacing = 4
                let indent = CGFloat(item.depth) * 24
                style.firstLineHeadIndent = indent
                style.headIndent = indent + 24
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 24)]
                let line = NSMutableAttributedString(string: marker, attributes: [
                    .font: theme.bodyFont,
                    .foregroundColor: color(for: role, theme: theme),
                    .paragraphStyle: style
                ])
                let content = NSMutableAttributedString(attributedString: prepareMarkdown(
                    item.text,
                    font: theme.bodyFont,
                    color: color(for: role, theme: theme),
                    theme: theme
                ).attributedString)
                if content.length > 0 {
                    content.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: content.length))
                }
                line.append(content)
                line.append(NSAttributedString(string: "\n", attributes: [
                    .font: theme.bodyFont,
                    .foregroundColor: color(for: role, theme: theme),
                    .paragraphStyle: style
                ]))
                result.append(line)
            }
            return CodexPreparedTranscriptText(result)
        case .blockquote(_, let text, _):
            let prepared = NSMutableAttributedString(attributedString: prepareMarkdown(
                text,
                font: theme.bodyFont,
                color: color(for: role, theme: theme),
                theme: theme
            ).attributedString)
            if prepared.length > 0 {
                let style = NSMutableParagraphStyle()
                style.lineSpacing = theme.lineSpacing
                style.headIndent = 16
                style.firstLineHeadIndent = 16
                prepared.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: prepared.length))
            }
            return CodexPreparedTranscriptText(prepared)
        case .horizontalRule:
            return preparePlain(
                "────────────────────────",
                font: theme.captionFont,
                color: theme.textTertiary,
                theme: theme
            )
        case .table(_, let model):
            return prepareTable(model, role: role, theme: theme)
        case .code:
            return preparePlain("", font: theme.codeFont, color: theme.codeText, theme: theme)
        case .math(_, let latex, _):
            return preparePlain(latex, font: theme.codeFont, color: theme.textPrimary, theme: theme)
        case .mermaid(_, let diagram, _):
            return preparePlain(diagram, font: theme.codeFont, color: theme.textPrimary, theme: theme)
        }
    }

    static func combine(
        _ blocks: [NSAttributedString],
        role: CodexTranscriptTextRole,
        theme: CodexTranscriptAppKitTheme
    ) -> CodexPreparedTranscriptText {
        let result = NSMutableAttributedString()
        let separatorAttributes: [NSAttributedString.Key: Any] = [
            .font: theme.bodyFont,
            .foregroundColor: color(for: role, theme: theme),
            .paragraphStyle: paragraphStyle(theme)
        ]
        for block in blocks where block.length > 0 {
            if result.length > 0 {
                let separator = "\n"
                result.append(NSAttributedString(string: separator, attributes: separatorAttributes))
            }
            result.append(block)
        }
        return CodexPreparedTranscriptText(result)
    }

    static func prepareMarkdown(
        _ markdown: String,
        font: NSFont,
        color: NSColor,
        theme: CodexTranscriptAppKitTheme
    ) -> CodexPreparedTranscriptText {
        let parsed = (try? NSAttributedString(markdown: Data(markdown.utf8), options: .init(), baseURL: nil))
            ?? NSAttributedString(string: markdown)
        let result = NSMutableAttributedString(attributedString: parsed)
        let fullRange = NSRange(location: 0, length: result.length)
        result.addAttributes([
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle(theme)
        ], range: fullRange)
        let presentationIntentKey = NSAttributedString.Key(
            AttributeScopes.FoundationAttributes.PresentationIntentAttribute.name
        )
        let inlinePresentationIntentKey = NSAttributedString.Key(
            AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.name
        )
        parsed.enumerateAttribute(inlinePresentationIntentKey, in: fullRange) { value, range, _ in
            let raw = (value as? NSNumber)?.uintValue ?? (value as? UInt)
            guard let raw else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            var resolved = font
            if intent.contains(.code) {
                resolved = theme.codeFont
                result.addAttribute(.backgroundColor, value: theme.surfaceSunken, range: range)
            } else {
                var traits: NSFontTraitMask = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                if !traits.isEmpty { resolved = NSFontManager.shared.convert(font, toHaveTrait: traits) }
            }
            result.addAttribute(.font, value: resolved, range: range)
        }
        parsed.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard value != nil else { return }
            result.addAttributes([
                .foregroundColor: theme.accent,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: range)
        }
        // Foundation's presentation intents describe Markdown structure. The
        // projector has already applied the paragraph and inline styling used
        // by AppKit, so retaining their parent-linked metadata only inflates
        // cache entries and makes otherwise ordinary Markdown look unsafe.
        result.removeAttribute(presentationIntentKey, range: fullRange)
        result.removeAttribute(inlinePresentationIntentKey, range: fullRange)
        return CodexPreparedTranscriptText(result)
    }

    static func preparePlain(
        _ text: String,
        font: NSFont,
        color: NSColor,
        theme: CodexTranscriptAppKitTheme
    ) -> CodexPreparedTranscriptText {
        // Plain text treats every newline as a paragraph break; markdown paragraph
        // spacing would add 10pt per line, so plain runs use line spacing only.
        let style = NSMutableParagraphStyle()
        style.lineSpacing = theme.lineSpacing
        return CodexPreparedTranscriptText(NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]))
    }

    static func prepareExpandedOutput(
        _ text: String,
        row: CodexWorkRowV2,
        theme: CodexTranscriptAppKitTheme
    ) -> CodexPreparedTranscriptText {
        guard case .command = row else {
            return preparePlain(text, font: theme.codeFont, color: theme.textSecondary, theme: theme)
        }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = theme.lineSpacing
        return CodexPreparedTranscriptText(ANSITerminalStyle.makeAppKitAttributedString(
            from: ANSIParser().parse(text),
            font: theme.codeFont,
            defaultForeground: theme.textSecondary,
            paragraphStyle: style
        ))
    }

    static func expandedOutputCacheStyle(for row: CodexWorkRowV2) -> String {
        switch row {
        case .command:
            return "expanded-output-command"
        default:
            return "expanded-output-plain"
        }
    }

    static func prepareUserMessage(
        _ user: CodexUserMessageV2,
        text: String,
        font: NSFont,
        color: NSColor,
        theme: CodexTranscriptAppKitTheme
    ) -> CodexPreparedTranscriptText {
        let result = NSMutableAttributedString(attributedString: preparePlain(text, font: font, color: color, theme: theme).attributedString)
        return CodexPreparedTranscriptText(result)
    }

    static func prepareTable(
        _ model: CodexTableModel,
        role: CodexTranscriptTextRole,
        theme: CodexTranscriptAppKitTheme
    ) -> CodexPreparedTranscriptText {
        guard !model.columns.isEmpty else {
            return preparePlain("", font: theme.bodyFont, color: color(for: role, theme: theme), theme: theme)
        }
        let table = NSTextTable()
        table.numberOfColumns = model.columns.count
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        let rows = [model.columns.map(\.header)] + model.rows
        let result = NSMutableAttributedString()
        for (rowIndex, row) in rows.enumerated() {
            for columnIndex in model.columns.indices {
                let block = NSTextTableBlock(
                    table: table,
                    startingRow: rowIndex,
                    rowSpan: 1,
                    startingColumn: columnIndex,
                    columnSpan: 1
                )
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setBorderColor(theme.border)
                if rowIndex == 0 { block.backgroundColor = theme.surfaceSunken }
                let style = NSMutableParagraphStyle()
                style.lineSpacing = theme.lineSpacing
                style.textBlocks = [block]
                switch model.columns[columnIndex].alignment {
                case .leading: style.alignment = .left
                case .center: style.alignment = .center
                case .trailing: style.alignment = .right
                }
                let text = columnIndex < row.count ? row[columnIndex] : ""
                let prepared = NSMutableAttributedString(attributedString: prepareMarkdown(
                    text,
                    font: theme.bodyFont,
                    color: color(for: role, theme: theme),
                    theme: theme
                ).attributedString)
                if prepared.length > 0 {
                    prepared.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: prepared.length))
                    if rowIndex == 0 {
                        prepared.addAttribute(
                            .font,
                            value: NSFontManager.shared.convert(theme.bodyFont, toHaveTrait: .boldFontMask),
                            range: NSRange(location: 0, length: prepared.length)
                        )
                    }
                }
                prepared.append(NSAttributedString(string: "\n", attributes: [
                    .font: theme.bodyFont,
                    .foregroundColor: color(for: role, theme: theme),
                    .paragraphStyle: style
                ]))
                result.append(prepared)
            }
        }
        return CodexPreparedTranscriptText(result)
    }

    static func paragraphStyle(_ theme: CodexTranscriptAppKitTheme) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = theme.lineSpacing
        style.paragraphSpacing = 10
        return style
    }

    static func color(for role: CodexTranscriptTextRole, theme: CodexTranscriptAppKitTheme) -> NSColor {
        theme.textPrimary
    }

    static func isStreaming(_ turn: CodexTurnV2) -> Bool {
        if case .working = turn.status { return true }
        if turn.finalAnswer?.isStreaming == true { return true }
        return turn.narrative.contains { entry in
            if case .prose(let prose) = entry { return prose.isStreaming }
            return false
        }
    }

    static func shouldRenderWork(_ turn: CodexTurnV2) -> Bool {
        switch turn.status {
        case .working:
            return turn.finalAnswer?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                || hasInProgressWork(turn)
        case .done, .failed:
            return !turn.narrative.isEmpty || turn.liveTail != nil
        }
    }

    static func isWorkTailMode(_ turn: CodexTurnV2) -> Bool {
        guard case .working = turn.status else { return false }
        return turn.finalAnswer?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    static func hasInProgressWork(_ turn: CodexTurnV2) -> Bool {
        turn.narrative.contains { entry in
            switch entry {
            case .workGroup(let group): group.rows.contains(where: \.isInProgress)
            case .productToolCall(let call): call.status == .inProgress
            case .inlineActivity(let activity): activity.status == .inProgress
            default: false
            }
        }
    }

    static func kind(for row: CodexWorkRowV2) -> CodexWorkRowKind {
        switch row {
        case .command: .command
        case .fileChange: .fileChange
        case .mcpToolCall: .mcp
        case .webSearch: .webSearch
        case .collabAgent: .agent
        case .other: .other
        }
    }

    static func renderNode(for row: CodexWorkRowV2) -> CodexTranscriptRenderNodeV2? {
        guard case .mcpToolCall(let value) = row,
              !value.contentBlocks.isEmpty else { return nil }
        return .mcpContent(value.contentBlocks)
    }

    static func workIsExpanded(_ turn: CodexTurnV2, presentation: CodexThreadUIPresentation) -> Bool {
        switch turn.status {
        case .working: true
        case .done: presentation.expandedWorkTurnIDs.contains(turn.id)
        case .failed: false
        }
    }

    static func workHeader(_ turn: CodexTurnV2, expanded: Bool, presentedAt: Date) -> CodexTranscriptWorkHeaderRender {
        switch turn.status {
        case .working(let since):
            let start = since.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? presentedAt
            return .init(state: .working(
                startedAt: start,
                showsDuration: CodexWorkBlockViewV2.showsWorkingDuration(narrative: turn.narrative, liveTail: turn.liveTail)
            ))
        case .done(let durationMs):
            return .init(state: .done(durationMs: durationMs, isExpanded: expanded))
        case .failed(let message):
            if let interruption = turn.status.interruption {
                return .init(state: .interrupted(
                    durationMs: interruption.durationMs,
                    message: interruption.message
                ))
            }
            return .init(state: .failed(message: message))
        }
    }

    static func workHeaderIsActionable(_ header: CodexTranscriptWorkHeaderRender) -> Bool {
        if case .done = header.state { return true }
        return false
    }

    static func workHeaderAccessibilityLabel(_ header: CodexTranscriptWorkHeaderRender) -> String {
        switch header.state {
        case .working(_, let showsDuration): return showsDuration ? "Working" : "Thinking"
        case .done(let duration, let expanded):
            return "\(CodexWorkBlockViewV2.completedLabel(duration)), \(expanded ? "expanded" : "collapsed")"
        case .interrupted(let duration, let message):
            let elapsed = duration.map { " after \(CodexWorkBlockViewV2.duration($0))" } ?? ""
            return "Interrupted\(elapsed)" + (message.isEmpty ? "" : ": \(message)")
        case .failed(let message): return message.isEmpty ? "Work failed" : message
        }
    }

    static func label(for row: CodexWorkRowV2) -> String {
        switch row {
        case .command(let value):
            return value.label.codexAppKitDisplayPrefix(limit: 280)
        case .fileChange(let value):
            return fileChangeLabel(value)
        case .mcpToolCall(let value):
            let app = value.appName.isEmpty ? value.server : value.appName
            let base = "Called \(app) · \(value.tool)"
            return value.errorFirstLine.map { base + " — " + $0 } ?? base
        case .webSearch(let value): return "Searched \(value.query)"
        case .collabAgent(let value): return value.label
        case .other(let value): return value.label
        }
    }

    static func systemImage(for row: CodexWorkRowV2) -> String? {
        guard case .command(let value) = row else { return nil }
        return switch value.action {
        case .read: "book"
        case .loadedTool: "book.closed"
        case .list: "list.bullet.rectangle"
        case .search: "magnifyingglass"
        default: nil
        }
    }

    static func status(for row: CodexWorkRowV2) -> CodexWorkItemStatusV2 {
        switch row {
        case .command(let value): value.status
        case .fileChange(let value): value.status
        case .mcpToolCall(let value): value.status
        case .webSearch(let value): value.status
        case .collabAgent(let value): value.status
        case .other(let value): value.status
        }
    }

    static func statusTitle(_ status: CodexWorkItemStatusV2) -> String {
        switch status {
        case .inProgress: "in progress"
        case .completed: "completed"
        case .failed: "failed"
        case .declined: "declined"
        case .unknown: "status unavailable"
        }
    }

    static func duration(for row: CodexWorkRowV2) -> Int? {
        switch row {
        case .command(let value): value.durationMs
        case .fileChange(let value): value.durationMs
        case .mcpToolCall(let value): value.durationMs
        default: nil
        }
    }

    static func exitCode(for row: CodexWorkRowV2) -> Int? {
        guard case .command(let value) = row else { return nil }
        return value.exitCode
    }

    static func detail(for row: CodexWorkRowV2) -> String? {
        switch row {
        case .command(let value): return value.output?.codexAppKitNilIfEmpty
        case .fileChange: return nil
        case .mcpToolCall(let value):
            return CodexMCPContentPresentationV2.toolDetail(
                arguments: value.arguments,
                blocks: value.contentBlocks
            )
        case .collabAgent(let value):
            guard value.action == .waited || value.action == .sentInput else { return nil }
            let ordered = value.orderedMessageAgentNames
            let replies = ordered.compactMap { agent in
                value.agentMessages[agent].map { "\(agent)\n\($0)" }
            }.joined(separator: "\n\n")
            let parts = [value.action == .sentInput ? value.instructions?.codexAppKitNilIfEmpty : nil, replies.codexAppKitNilIfEmpty].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        case .webSearch(let value):
            let results = value.results.prefix(12).map { result in
                [result.title, result.url, result.snippet]
                    .compactMap { $0?.codexAppKitNilIfEmpty }
                    .joined(separator: "\n")
            }
            return results.isEmpty ? nil : results.joined(separator: "\n\n")
        default: return nil
        }
    }

    static func subagentThreadID(for row: CodexWorkRowV2) -> String? {
        guard case .collabAgent(let value) = row else { return nil }
        return value.agentThreadIDs.first
    }

    static func accessibilityLabel(for row: CodexWorkRowV2, render: CodexTranscriptWorkRowRender) -> String {
        let state = switch render.status {
        case .inProgress: "in progress"
        case .completed: "completed"
        case .failed: "failed"
        case .declined: "declined"
        case .unknown: "unknown status"
        }
        let outcome: String? = {
            guard case .command(let value) = row else { return nil }
            return value.executionStateLabel
        }()
        return [render.label, outcome ?? state].joined(separator: ", ")
    }

    static func inlineActivityAccessibilityLabel(
        _ activity: CodexInlineActivityV2,
        isExpanded: Bool = false
    ) -> String {
        let state = switch activity.status {
        case .inProgress: "in progress"
        case .completed: "completed"
        case .failed: "failed"
        case .declined: "declined"
        case .unknown: "unknown status"
        }
        let hasExpandableContent = activity.detail?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || activity.imagePath?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let disclosure = hasExpandableContent
            ? ", \(isExpanded ? "details shown" : "details hidden")"
            : ""
        return "\(activity.label), \(state)\(disclosure)"
    }

    static func bounded(_ text: String, limit: Int) -> String {
        text.codexAppKitDisplayPrefix(limit: limit)
    }

    static func copyText(for turn: CodexTurnV2) -> String {
        var parts: [String] = []
        if let user = turn.userMessage?.displayText.codexAppKitNilIfEmpty { parts.append("You\n" + user) }
        var work: [String] = []
        func flushWork() {
            guard !work.isEmpty else { return }
            parts.append("Work\n" + work.joined(separator: "\n"))
            work.removeAll(keepingCapacity: true)
        }
        for segment in turn.conversationSegments {
            if let user = segment.steeredMessage?.displayText.codexAppKitNilIfEmpty {
                flushWork()
                parts.append("You\n" + user)
            }
            for entry in segment.narrative {
                switch entry {
                case .prose(let prose): if !prose.text.isEmpty { work.append(prose.text) }
                case .workGroup(let group):
                    work.append(group.header)
                    work.append(contentsOf: group.rows.map { row in
                        [label(for: row), detail(for: row)].compactMap { $0 }.joined(separator: "\n")
                    })
                case .productToolCall(let call):
                    let label = [call.namespace, call.tool].compactMap { $0 }.joined(separator: " · ")
                    let payload = CodexMCPContentPresentationV2.summary(
                        call.contentItems.compactMap(CodexMCPContentBlockAdapter.decode)
                    )
                    work.append([label, payload].compactMap { $0 }.joined(separator: "\n"))
                case .inlineActivity(let activity): work.append(activity.label)
                case .structuredCard(let card): work.append(card.title)
                case .approvalReview(let review): work.append("\(review.title): \(review.statusLabel)")
                case .hookActivity(let hook): work.append(hook.label)
                case .recovery(let recovery): work.append(recovery.message)
                case .notice(let notice): work.append(notice.message)
                }
            }
        }
        flushWork()
        if let answer = turn.finalAnswer?.text.codexAppKitNilIfEmpty { parts.append("Assistant\n" + answer) }
        return parts.joined(separator: "\n\n")
    }

    private static func retryUserMessage(
        for draft: ItemDraft,
        turn: CodexTurnV2
    ) -> CodexUserMessageV2? {
        guard let userMessage = turn.userMessage else { return nil }
        switch turn.status {
        case .working:
            return nil
        case .done:
            if draft.footer?.kind == .finalAnswer { return userMessage }
            guard turn.finalAnswer?.text.isEmpty != false else { return nil }
            return draft.workHeader == nil ? nil : userMessage
        case .failed:
            if draft.footer?.kind == .finalAnswer { return userMessage }
            guard turn.finalAnswer?.text.isEmpty != false else { return nil }
            return draft.workHeader == nil ? nil : userMessage
        }
    }
}

extension CodexTranscriptRenderProjector {
    static func prepareMinimapPreviewMarkdown(
        _ markdown: String,
        theme: CodexTranscriptAppKitTheme
    ) -> NSAttributedString {
        prepareMarkdown(
            markdown,
            font: theme.captionFont,
            color: theme.textSecondary,
            theme: theme
        ).attributedString
    }
}

private extension CodexBlock {
    var isCodeV2: Bool {
        switch self {
        case .code, .math, .mermaid: return true
        default: return false
        }
    }
}

private extension String {
    var codexAppKitNilIfEmpty: String? { isEmpty ? nil : self }

    func codexAppKitDisplayPrefix(limit: Int) -> String {
        guard let boundary = index(startIndex, offsetBy: limit, limitedBy: endIndex), boundary != endIndex else { return self }
        return String(self[..<boundary]) + "\n… Output truncated for display"
    }
}
