import XCTest
import CodexCore
import CodexCoreUI

final class CodexComposerDraftTests: XCTestCase {
    private let firstFile = CodexReferencedFile(path: "/tmp/first.png", kind: .image)
    private let secondFile = CodexReferencedFile(path: "/tmp/second.md", kind: .file)

    private func skill(_ name: String = "review") -> CodexSlashCommand {
        CodexSlashCommand(
            id: "skill:\(name)", title: name, detail: "A scoped skill", systemImage: "shippingbox",
            section: "Skills", scopeBadge: "Local", skillName: name, skillPath: "/skills/\(name)/SKILL.md"
        )
    }

    private func mention(_ name: String = "Store.swift", root: String = "/repo") -> FuzzyFileSearchResult {
        FuzzyFileSearchResult(fileName: name, matchType: .file, path: name, root: root, score: 0.9, indices: [0, 1])
    }

    private func annotation(_ id: String = "selection") -> CodexResponseTextAnnotation {
        CodexResponseTextAnnotation(id: id, text: "Selected response", annotation: "Explain this",
            anchor: .init(renderItemID: "render-item", startOffset: 4, endOffset: 21))
    }

    func testIndependentPreThreadDraftsOwnTextFilesAnnotationsSkillsAndMentions() throws {
        var composer = CodexComposerStateSession()
        let first = composer.newDraft(workspacePath: "/repo", projectID: "project-a")
        composer.draft = "Inspect @Store.swift"
        composer.referencedFiles = [firstFile]
        composer.responseAnnotations = [annotation()]
        composer.attachSkill(skill())
        composer.selectMention(mention(root: "/first"))

        let second = composer.newDraft(workspacePath: "/repo", projectID: "project-b")
        XCTAssertNotEqual(first, second)
        XCTAssertNil(composer.activeThreadID)
        XCTAssertTrue(composer.draft.isEmpty)
        XCTAssertTrue(composer.attachedSkills.isEmpty)
        composer.draft = "Second @Store.swift"
        composer.referencedFiles = [secondFile]
        composer.attachSkill(skill("second"))
        composer.selectMention(mention(root: "/second"))

        composer.setActiveDraftID(first)
        composer.setActiveThreadID(nil) // Repeated legacy synchronization preserves explicit nil-thread ownership.
        XCTAssertEqual(composer.draft(for: nil), "Inspect @Store.swift")
        XCTAssertEqual(composer.referencedFiles(for: nil), [firstFile])
        XCTAssertEqual(composer.responseAnnotations, [annotation()])
        XCTAssertEqual(composer.attachedSkills, [skill()])
        let submission = try XCTUnwrap(composer.consumeDraftForTurn())
        XCTAssertEqual(submission.draftID, first)
        XCTAssertNil(submission.threadID)
        XCTAssertEqual(submission.mentions, [.mention(name: "Store.swift", path: "/first/Store.swift")])
        XCTAssertEqual(composer.draft(for: second), "Second @Store.swift")

        composer.setActiveDraftID(second)
        XCTAssertEqual(composer.attachedSkills, [skill("second")])
        XCTAssertEqual(composer.consumeDraftForTurn()?.mentions, [.mention(name: "Store.swift", path: "/second/Store.swift")])
    }

    func testExistingThreadContextSurvivesSwitchAndTransientReset() throws {
        var composer = CodexComposerStateSession(draft: "Inspect @Store.swift", activeThreadID: "thread-a")
        composer.attachSkill(skill())
        composer.selectMention(mention())
        composer.setActiveThreadID("thread-b")
        composer.clearThreadState()
        XCTAssertTrue(composer.attachedSkills.isEmpty)
        composer.draft = "Thread B"
        composer.setActiveThreadID("thread-a")
        composer.clearThreadState()
        XCTAssertEqual(composer.attachedSkills, [skill()])
        XCTAssertEqual(composer.consumeDraftForFollowUp()?.mentions,
            [.mention(name: "Store.swift", path: "/repo/Store.swift")])
        XCTAssertEqual(composer.draft(for: "thread-b"), "Thread B")
    }

    func testFailedSubmissionRestoresOriginAndPreservesTypingAfterDraftSwitch() throws {
        var composer = CodexComposerStateSession()
        let origin = composer.newDraft(workspacePath: "/repo")
        composer.draft = "Original @Store.swift"
        composer.referencedFiles = [firstFile]
        composer.responseAnnotations = [annotation()]
        composer.attachSkill(skill())
        composer.selectMention(mention())
        let submission = try XCTUnwrap(composer.consumeDraftForTurn())
        composer.draft = "New typing @Other.swift"
        composer.referencedFiles = [secondFile]
        composer.selectMention(mention("Other.swift"))

        let other = composer.newDraft(workspacePath: "/other", isProjectless: true)
        composer.draft = "Other draft"
        composer.attachSkill(skill("other"))
        composer.restore(submission)
        XCTAssertEqual(composer.activeDraftID, other)
        XCTAssertEqual(composer.draft, "Other draft")
        XCTAssertEqual(composer.attachedSkills, [skill("other")])
        XCTAssertEqual(composer.draft(for: origin), "Original @Store.swift\n\nNew typing @Other.swift")
        XCTAssertEqual(composer.referencedFiles(for: origin), [firstFile, secondFile])
        composer.setActiveDraftID(origin)
        let retry = try XCTUnwrap(composer.consumeDraftForTurn())
        XCTAssertEqual(retry.skills, [skill()])
        XCTAssertEqual(retry.responseAnnotations, [annotation()])
        XCTAssertEqual(retry.mentions, [
            .mention(name: "Other.swift", path: "/repo/Other.swift"),
            .mention(name: "Store.swift", path: "/repo/Store.swift"),
        ])
    }

    func testPromotionPreservesOriginTypingAndFailedSubmissionRestoresAfterNativeBinding() throws {
        var composer = CodexComposerStateSession()
        let origin = composer.newDraft(workspacePath: "/repo", projectID: "native-project")
        composer.draft = "Launch"
        var submission = try XCTUnwrap(composer.consumeDraftForTurn())
        let clientID = submission.clientID
        composer.draft = "Typing while launch is pending"
        composer.referencedFiles = [secondFile]
        let selected = composer.newDraft(workspacePath: "/other")
        composer.draft = "Selected draft"

        submission.threadID = "native-thread"
        composer.promoteDraft(origin, to: "native-thread")
        XCTAssertEqual(submission.clientID, clientID)
        XCTAssertEqual(composer.activeDraftID, selected)
        XCTAssertNil(composer.activeThreadID)
        XCTAssertEqual(composer.draft(for: "native-thread"), "Typing while launch is pending")
        composer.restore(submission)
        XCTAssertEqual(composer.draft, "Selected draft")
        XCTAssertEqual(composer.draft(for: origin), "Launch\n\nTyping while launch is pending")
        composer.setActiveThreadID("native-thread")
        XCTAssertEqual(composer.activeDraftID, origin)
        XCTAssertEqual(composer.activeThreadID, "native-thread")
        XCTAssertEqual(composer.referencedFiles, [secondFile])
        let record = try XCTUnwrap(composer.draftRecords.first { $0.draftID == origin })
        XCTAssertEqual(record.threadID, "native-thread")
        XCTAssertEqual(record.projectID, "native-project")
    }

    func testPromotionMergesExistingNativeDraftWithoutDroppingEitherContext() {
        var composer = CodexComposerStateSession(activeThreadID: "native-thread")
        composer.draft = "Existing native draft"
        composer.referencedFiles = [secondFile]
        composer.attachSkill(skill("existing"))
        let origin = composer.newDraft(workspacePath: "/repo")
        composer.draft = "New typing"
        composer.referencedFiles = [firstFile]
        composer.attachSkill(skill())
        composer.promoteDraft(origin, to: "native-thread")
        XCTAssertEqual(composer.draft, "New typing\n\nExisting native draft")
        XCTAssertEqual(composer.referencedFiles, [firstFile, secondFile])
        XCTAssertEqual(composer.attachedSkills, [skill(), skill("existing")])
        XCTAssertEqual(composer.draftRecords.filter { $0.threadID == "native-thread" }.count, 1)
    }

    func testSnapshotRoundTripPreservesCompleteContextAndActiveSelection() throws {
        var composer = CodexComposerStateSession(followUpBehavior: .queue)
        let first = composer.newDraft(workspacePath: "/repo", projectID: "opaque-project")
        composer.draft = "Inspect @Store.swift"
        composer.referencedFiles = [firstFile, secondFile]
        composer.responseAnnotations = [annotation()]
        composer.attachSkill(skill())
        composer.selectMention(mention())
        composer.setDraft("Inactive native text", for: "native-thread")
        let second = composer.newDraft(workspacePath: "/other", isProjectless: true)
        composer.draft = "Second draft"
        composer.sideChatDraft = "Transient side chat"
        composer.setMentionResults([mention()])
        composer.setActiveThreadID("native-thread")
        composer.enqueueFollowUp("Authoritative queue is hydrated separately")
        composer.setActiveDraftID(second)

        let snapshot = try composer.draftSnapshot()
        let decoded = try CodexComposerDraftsSnapshot.decode(snapshot.encoded())
        XCTAssertEqual(decoded, snapshot)
        var restored = try CodexComposerStateSession(restoring: decoded, followUpBehavior: .queue)
        XCTAssertEqual(try restored.draftSnapshot(), snapshot)
        XCTAssertEqual(restored.activeDraftID, second)
        XCTAssertEqual(restored.draft, "Second draft")
        XCTAssertTrue(restored.sideChatDraft.isEmpty)
        XCTAssertTrue(restored.mentionResults.isEmpty)
        XCTAssertTrue(restored.queuedFollowUpSubmissions(for: "native-thread").isEmpty)
        XCTAssertEqual(restored.draft(for: "native-thread"), "Inactive native text")
        restored.setActiveDraftID(first)
        XCTAssertEqual(restored.referencedFiles, [firstFile, secondFile])
        XCTAssertEqual(restored.responseAnnotations, [annotation()])
        XCTAssertEqual(restored.attachedSkills, [skill()])
        XCTAssertEqual(restored.consumeDraftForTurn()?.mentions, [.mention(name: "Store.swift", path: "/repo/Store.swift")])
        XCTAssertEqual(snapshot.drafts.first { $0.draftID == second }?.isProjectless, true)
    }

    func testSnapshotRejectsInvalidIdentityVersionDuplicatesAndBounds() throws {
        let id = CodexComposerDraftID()
        let record = CodexComposerDraftSnapshot(draftID: id, prompt: "Valid")
        let snapshot = try CodexComposerDraftsSnapshot(activeDraftID: id, drafts: [record])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.encoded()) as? [String: Any])
        json["version"] = 99
        XCTAssertThrowsError(try CodexComposerDraftsSnapshot.decode(JSONSerialization.data(withJSONObject: json)))
        XCTAssertThrowsError(try CodexComposerDraftsSnapshot(activeDraftID: id, drafts: [record, record]))
        XCTAssertThrowsError(try CodexComposerDraftsSnapshot(activeDraftID: .init(), drafts: [record]))
        XCTAssertThrowsError(try CodexComposerDraftsSnapshot(activeDraftID: id, drafts: [
            .init(draftID: id, threadID: "same"), .init(draftID: .init(), threadID: "same"),
        ]))
        XCTAssertThrowsError(try CodexComposerDraftsSnapshot(activeDraftID: id, drafts: [
            .init(draftID: id, prompt: String(repeating: "a", count: 256 * 1_024 + 1)),
        ]))
        XCTAssertThrowsError(try CodexComposerDraftsSnapshot.decode(Data(repeating: 32,
            count: CodexComposerDraftsSnapshot.maximumEncodedBytes + 1)))
        let invalid = CodexComposerDraftID(rawValue: " ")
        XCTAssertThrowsError(try CodexComposerDraftsSnapshot(activeDraftID: invalid, drafts: [.init(draftID: invalid)]))
        let tooMany = (0...CodexComposerDraftsSnapshot.maximumDrafts).map { _ in
            CodexComposerDraftSnapshot(draftID: .init())
        }
        XCTAssertThrowsError(try CodexComposerDraftsSnapshot(activeDraftID: tooMany[0].draftID, drafts: tooMany))
    }

    func testSnapshotRejectsInvalidAnnotationsAndRelativeWorkspacePaths() {
        let id = CodexComposerDraftID()
        let invalidAnnotation = CodexResponseTextAnnotation(text: "Invalid",
            anchor: .init(renderItemID: "item", startOffset: 8, endOffset: 2))
        XCTAssertThrowsError(try CodexComposerDraftsSnapshot(activeDraftID: id, drafts: [
            .init(draftID: id, responseAnnotations: [invalidAnnotation]),
        ]))
        XCTAssertThrowsError(try CodexComposerDraftsSnapshot(activeDraftID: id, drafts: [
            .init(draftID: id, workspacePath: "relative/path"),
        ]))
        XCTAssertThrowsError(try CodexComposerDraftsSnapshot(activeDraftID: id, drafts: [
            .init(draftID: id, selectedMentions: [mention(), mention()]),
        ]))
    }

    func testAtomicFileStorageRoundTripAndOversizeFailurePreservesExistingSnapshot() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("codex-drafts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = CodexComposerDraftFileStorage(fileURL: folder.appendingPathComponent("drafts.json"))
        XCTAssertNil(try storage.load())
        var composer = CodexComposerStateSession()
        let id = composer.newDraft(workspacePath: "/repo")
        composer.draft = "Durable text"
        let snapshot = try composer.draftSnapshot()
        try storage.save(snapshot)
        XCTAssertEqual(try storage.load(), snapshot)

        let largeRecords = (0..<24).map { index in
            CodexComposerDraftSnapshot(draftID: .init(rawValue: "draft:\(index)"),
                prompt: String(repeating: "a", count: 200 * 1_024))
        }
        let tooLarge = try CodexComposerDraftsSnapshot(activeDraftID: largeRecords[0].draftID, drafts: largeRecords)
        XCTAssertThrowsError(try storage.save(tooLarge))
        XCTAssertEqual(try storage.load()?.activeDraftID, id)
        XCTAssertEqual(try storage.load(), snapshot)
        try Data(repeating: 32, count: CodexComposerDraftsSnapshot.maximumEncodedBytes + 1)
            .write(to: storage.fileURL, options: .atomic)
        XCTAssertThrowsError(try storage.load())
    }

    func testLegacyDraftInitializerAndDiscardRemainSourceCompatible() throws {
        var composer = CodexComposerStateSession(draftByThreadID: [
            "thread-a": "Draft A", "__codex_unassigned_draft__": "Legacy nil draft",
        ])
        XCTAssertEqual(composer.activeDraftID, .unassigned)
        XCTAssertEqual(composer.draft, "Legacy nil draft")
        composer.setActiveThreadID("thread-a")
        XCTAssertEqual(composer.draft, "Draft A")
        composer.discardThreadState(for: "thread-a")
        XCTAssertEqual(composer.draft(for: "thread-a"), "")
        XCTAssertEqual(composer.draft, "Legacy nil draft")
        let decoded = try CodexComposerDraftsSnapshot.decode(composer.draftSnapshot().encoded())
        XCTAssertEqual(decoded.drafts.map(\.draftID), [.unassigned])
    }

    func testHydrationPreservesLiveQueueSearchPolicyAndNewTyping() throws {
        let id = CodexComposerDraftID()
        var persisted = CodexComposerStateSession(activeDraftID: id)
        persisted.draft = "Saved @Store.swift"
        persisted.referencedFiles = [firstFile]
        persisted.responseAnnotations = [annotation()]
        persisted.attachSkill(skill())
        persisted.selectMention(mention())
        persisted.setActiveDraftID(id, workspacePath: "/repo", projectID: "saved-project")

        var live = CodexComposerStateSession(followUpBehavior: .queue, activeDraftID: id)
        live.draft = "New typing @Other.swift"
        live.referencedFiles = [secondFile]
        live.selectMention(mention("Other.swift"))
        live.setMentionResults([mention("Search.swift")])
        let queued = CodexComposerSubmission(prompt: "Failed local follow-up", clientID: "queued-client", threadID: "thread")
        live.requeueFollowUp(queued)
        live.sideChatDraft = "Live side chat"
        live.mergeDrafts(from: persisted)
        live.mergeDrafts(from: persisted)

        XCTAssertEqual(live.activeDraftID, id)
        XCTAssertNil(live.activeThreadID)
        XCTAssertEqual(live.followUpBehavior, .queue)
        XCTAssertEqual(live.sideChatDraft, "Live side chat")
        XCTAssertEqual(live.mentionResults, [mention("Search.swift")])
        XCTAssertEqual(live.queuedFollowUpSubmissions(for: "thread"), [queued])
        XCTAssertEqual(live.draft, "Saved @Store.swift\n\nNew typing @Other.swift")
        XCTAssertEqual(live.referencedFiles, [secondFile, firstFile])
        XCTAssertEqual(live.responseAnnotations, [annotation()])
        XCTAssertEqual(live.attachedSkills, [skill()])
        XCTAssertEqual(live.draftRecords.first { $0.draftID == id }?.projectID, "saved-project")
        XCTAssertEqual(live.consumeDraftForTurn()?.mentions, [
            .mention(name: "Other.swift", path: "/repo/Other.swift"),
            .mention(name: "Store.swift", path: "/repo/Store.swift"),
        ])
    }

    func testHydrationUsesExistingNativeBindingWhenPersistedDraftHasDifferentIdentity() throws {
        var persisted = CodexComposerStateSession()
        let persistedID = persisted.newDraft(workspacePath: "/repo")
        persisted.draft = "Saved native text"
        persisted.referencedFiles = [firstFile]
        persisted.promoteDraft(persistedID, to: "native-thread")

        var live = CodexComposerStateSession(activeThreadID: "native-thread")
        let liveID = live.activeDraftID
        live.draft = "Later native typing"
        live.referencedFiles = [secondFile]
        live.enqueueFollowUp("Local queued follow-up")
        live.mergeDrafts(from: persisted, activateRestoredDraft: true)
        live.mergeDrafts(from: persisted)

        XCTAssertEqual(live.activeDraftID, liveID)
        XCTAssertEqual(live.activeThreadID, "native-thread")
        XCTAssertEqual(live.draft, "Saved native text\n\nLater native typing")
        XCTAssertEqual(live.referencedFiles, [secondFile, firstFile])
        XCTAssertEqual(live.queuedFollowUps, ["Local queued follow-up"])
        XCTAssertEqual(live.draftRecords.filter { $0.threadID == "native-thread" }.map(\.draftID), [liveID])
        XCTAssertEqual(live.draft(for: persistedID), "")
        _ = try live.draftSnapshot()
    }

    func testRestoredActivationIsExplicitAndDoesNotOverrideInvestedDrafts() {
        var restored = CodexComposerStateSession()
        let restoredID = restored.newDraft(workspacePath: "/repo")
        restored.draft = "Saved text"
        var initial = CodexComposerStateSession()
        initial.mergeDrafts(from: restored)
        XCTAssertEqual(initial.activeDraftID, .unassigned)
        initial.mergeDrafts(from: restored, activateRestoredDraft: true)
        XCTAssertEqual(initial.activeDraftID, .unassigned) // An already imported invested draft blocks implicit selection changes.

        var empty = CodexComposerStateSession()
        empty.mergeDrafts(from: restored, activateRestoredDraft: true)
        XCTAssertEqual(empty.activeDraftID, restoredID)
        XCTAssertEqual(empty.draft, "Saved text")
        var typing = CodexComposerStateSession(draft: "User typing")
        typing.mergeDrafts(from: restored, activateRestoredDraft: true)
        XCTAssertEqual(typing.activeDraftID, .unassigned)
        XCTAssertEqual(typing.draft, "User typing")
    }

    func testPristineUnassignedMetadataYieldsToRestoredContextButInvestedMetadataDoesNot() throws {
        var restored = CodexComposerStateSession()
        restored.setActiveDraftID(.unassigned, workspacePath: "/project-a", projectID: "project-a", isProjectless: false)
        restored.draft = "Saved project text"
        var bootstrap = CodexComposerStateSession()
        bootstrap.setActiveDraftID(.unassigned, workspacePath: "/home", isProjectless: true)
        bootstrap.mergeDrafts(from: restored)
        let restoredRecord = try XCTUnwrap(bootstrap.draftRecords.first { $0.draftID == .unassigned })
        XCTAssertEqual(restoredRecord.workspacePath, "/project-a")
        XCTAssertEqual(restoredRecord.projectID, "project-a")
        XCTAssertFalse(restoredRecord.isProjectless)

        var invested = CodexComposerStateSession()
        invested.setActiveDraftID(.unassigned, workspacePath: "/home", isProjectless: true)
        invested.draft = "Live typing"
        invested.mergeDrafts(from: restored)
        let investedRecord = try XCTUnwrap(invested.draftRecords.first { $0.draftID == .unassigned })
        XCTAssertEqual(investedRecord.workspacePath, "/home")
        XCTAssertTrue(investedRecord.isProjectless)
    }

    func testEmptyExplicitDraftSelectionSurvivesRequestedRestoredActivation() {
        var restored = CodexComposerStateSession()
        restored.newDraft(workspacePath: "/repo")
        restored.draft = "Saved text"
        var live = CodexComposerStateSession()
        let explicitlySelectedID = live.newDraft(workspacePath: "/repo")
        live.mergeDrafts(from: restored, activateRestoredDraft: true)
        XCTAssertEqual(live.activeDraftID, explicitlySelectedID)
        XCTAssertTrue(live.draft.isEmpty)
    }

    func testActiveDraftRecordMatchesItsStoredRecordWithContextAndAttachments() {
        var composer = CodexComposerStateSession()
        composer.newDraft(workspacePath: "/inactive")
        composer.draft = "Inactive text"
        let activeID = composer.newDraft(workspacePath: "/active", projectID: "opaque-project")
        composer.draft = "Active text"
        composer.referencedFiles = [firstFile]
        composer.attachSkill(skill())
        composer.selectMention(mention())
        let active = composer.activeDraftRecord
        XCTAssertEqual(active.draftID, activeID)
        XCTAssertEqual(active.workspacePath, "/active")
        XCTAssertEqual(active.projectID, "opaque-project")
        XCTAssertEqual(active.referencedFiles, [firstFile])
        XCTAssertEqual(active.attachedSkills, [skill()])
        XCTAssertEqual(active, composer.draftRecords.first { $0.draftID == activeID })
        let emptyID = composer.newDraft(workspacePath: "/empty")
        composer.setActiveDraftID(activeID)
        XCTAssertFalse(composer.draftRecords.contains { $0.draftID == emptyID })
        XCTAssertEqual(composer.draftRecord(for: emptyID)?.workspacePath, "/empty")
        composer.setDraftContext(workspacePath: "/captured-empty", projectID: nil, isProjectless: true, for: emptyID)
        XCTAssertEqual(composer.activeDraftID, activeID)
        XCTAssertEqual(composer.draft, "Active text")
        XCTAssertEqual(composer.draftRecord(for: emptyID)?.workspacePath, "/captured-empty")
        XCTAssertTrue(composer.draftRecord(for: emptyID)?.isProjectless == true)
        composer.discardDraft(emptyID)
        XCTAssertNil(composer.draftRecord(for: emptyID))
    }
}
