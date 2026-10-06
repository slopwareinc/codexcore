import CodexCore
@testable import CodexCoreUI
import Testing

struct CodexSidebarDraftTests {
    @Test func onlyInvestedPreThreadDraftsAppearIncludingAttachmentAndContextOnlyDrafts() {
        let records: [CodexComposerDraftSnapshot] = [
            draft("text", prompt: "Unsent prompt"),
            draft("empty"),
            draft("whitespace", prompt: " \n\t "),
            draft("promoted", threadID: "native-thread", prompt: "Unsent native follow-up"),
            .init(draftID: id("image"), referencedFiles: [.init(path: "/tmp/image.png", kind: .image)]),
            .init(draftID: id("selection"), responseAnnotations: [selection]),
            .init(draftID: id("skill"), attachedSkills: [skill]),
        ]
        let items = CodexSidebarDraftProjection(drafts: records, projects: []).items
        #expect(items.map(\.id) == [id("image"), id("selection"), id("skill"), id("text")])
        #expect(items.first?.title == "1 attachment")
    }

    @Test func opaqueProjectScopeNeverGuessesSharedPathsAndProjectlessAppearsOnlyInAllProjects() {
        let alpha = CodexProjectSummary(workspacePath: "/shared", customDisplayName: "Alpha", serverID: "alpha")
        let beta = CodexProjectSummary(workspacePath: "/shared", customDisplayName: "Beta", serverID: "beta")
        let records = [
            draft("alpha", projectID: "alpha", prompt: "Alpha prompt"),
            draft("beta", projectID: "beta", prompt: "Beta prompt"),
            draft("legacy", prompt: "Unscoped prompt"),
            draft("projectless", projectID: "beta", isProjectless: true, prompt: "Projectless prompt"),
        ]
        let all = CodexSidebarDraftProjection(drafts: records, projects: [alpha, beta]).items
        #expect(all.count == 4)
        #expect(all.first { $0.id == id("alpha") }?.projectTitle == "Alpha")
        #expect(all.first { $0.id == id("beta") }?.projectTitle == "Beta")
        #expect(all.first { $0.id == id("projectless") }?.projectTitle == "Projectless")
        let scoped = CodexSidebarDraftProjection(drafts: records, projects: [alpha, beta], projectScopeID: "beta").items
        #expect(scoped.map(\.id) == [id("beta")])
        #expect(CodexSidebarDraftProjection(drafts: records, projects: [alpha, beta], projectScopeID: "unknown").items.isEmpty)
    }

    @Test func selectionAndOrderRemainStableAcrossPromptAndProjectNameChanges() {
        let first = draft("first", projectID: "project", prompt: "First title\nMore details")
        let second = draft("second", projectID: "project", prompt: "Second title")
        let oldProject = CodexProjectSummary(workspacePath: "/shared", customDisplayName: "Old name", serverID: "project")
        let newProject = CodexProjectSummary(workspacePath: "/shared", customDisplayName: "New name", serverID: "project")
        let before = CodexSidebarDraftProjection(drafts: [second, first], projects: [oldProject], activeDraftID: first.draftID).items
        let after = CodexSidebarDraftProjection(drafts: [
            draft("second", projectID: "project", prompt: "An alphabetically earlier title"),
            draft("first", projectID: "project", prompt: "A longer changed title\nDifferent details"),
        ], projects: [newProject], activeDraftID: first.draftID).items
        #expect(before.map(\.id) == after.map(\.id))
        #expect(before.first?.isSelected == true)
        #expect(after.first?.isSelected == true)
        #expect(after.first?.projectTitle == "New name")
        #expect(before.first?.title == "First title")
        #expect(after.first?.title == "A longer changed title")
    }

    @Test func previewsUseOnlyFirstPromptLineOrExplicitAttachmentAndContextLabels() {
        #expect(CodexSidebarDraftProjection.title(for: draft("text", prompt: "\n  First line  \nSecond line")) == "First line")
        let files: [CodexReferencedFile] = [.init(path: "/tmp/image.png", kind: .image), .init(path: "/tmp/context.md", kind: .file)]
        #expect(CodexSidebarDraftProjection.title(for: .init(draftID: id("file"), referencedFiles: [files[0]])) == "1 attachment")
        #expect(CodexSidebarDraftProjection.title(for: .init(draftID: id("files"), referencedFiles: files,
            responseAnnotations: [selection])) == "3 attachments")
        #expect(CodexSidebarDraftProjection.title(for: .init(draftID: id("skill"), attachedSkills: [skill])) == "Skill: Review")
        let mention = FuzzyFileSearchResult(fileName: "Store.swift", matchType: .file, path: "Store.swift", root: "/repo", score: 1)
        #expect(CodexSidebarDraftProjection.title(for: .init(draftID: id("mention"), selectedMentions: [mention])) == "Mention: Store.swift")
    }

    @Test func duplicateIdentitiesDoNotMountTwoDraftRows() {
        let first = draft("same", prompt: "First snapshot")
        let duplicate = draft("same", prompt: "Duplicate snapshot")
        let items = CodexSidebarDraftProjection(drafts: [first, duplicate], projects: []).items
        #expect(items.count == 1)
        #expect(items.first?.title == "First snapshot")
    }

    @MainActor
    @Test func publicSidebarEmbeddingAcceptsDraftDataAndCallbacksWithoutAHostModel() {
        let value = draft("example", projectID: "opaque-project", prompt: "Recover this draft")
        let snapshot = CodexSidebarSnapshot(selectedRoute: .chat, lastContentRoute: .chat,
            isCollapsed: false, isSearchOverlayPresented: false, selectedProjectPath: "/shared",
            selectedThreadID: nil, projects: [], showsNoChats: true)
        let sidebar = CodexProjectSidebar(
            serverName: nil, isThreadReady: false, snapshot: snapshot,
            onNewChat: {}, onOpenSearch: {}, onSelectRoute: { _ in }, onToggleProject: { _ in },
            onStartProjectChat: { _ in }, onSelectProject: { _ in }, onOpenFolder: {},
            onSelectChat: { _ in }, onTogglePinChat: { _ in }, onArchiveChat: { _ in },
            drafts: [value], activeDraftID: value.draftID,
            onSelectDraft: { _ in }, onDiscardDraft: { _ in }
        )
        #expect(sidebar.drafts == [value])
        #expect(sidebar.activeDraftID == value.draftID)
    }

    private func id(_ value: String) -> CodexComposerDraftID { .init(rawValue: "draft:" + value) }
    private func draft(_ value: String, threadID: String? = nil, projectID: String? = nil,
                       isProjectless: Bool = false, prompt: String = "") -> CodexComposerDraftSnapshot {
        .init(draftID: id(value), threadID: threadID, workspacePath: "/shared", projectID: projectID,
            isProjectless: isProjectless, prompt: prompt)
    }
    private var selection: CodexResponseTextAnnotation {
        .init(id: "selection", text: "Prior answer", anchor: .init(renderItemID: "item", startOffset: 0, endOffset: 5))
    }
    private var skill: CodexSlashCommand {
        .init(id: "review", title: "Review", detail: "Review skill", systemImage: "hammer",
            skillName: "review", skillPath: "/skills/review/SKILL.md")
    }
}
