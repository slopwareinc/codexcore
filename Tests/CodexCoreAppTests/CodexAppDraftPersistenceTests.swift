import Foundation
import CodexCore
import CodexCoreUI
@testable import CodexCoreApp
import Testing

struct CodexAppDraftPersistenceTests {
    private func rootURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("codex-app-drafts-\(UUID())", isDirectory: true)
    }

    private func record(_ text: String, id: CodexComposerDraftID = .init()) -> CodexComposerDraftSnapshot {
        .init(draftID: id, workspacePath: "/repo", prompt: text)
    }

    @Test func constructionDoesNotAccessFilesystemAndSuccessfulRevisionsRejectLateStaleWrites() async throws {
        let root = rootURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DraftPersistenceTestStorage()
        let persistence = CodexAppDraftPersistence(rootURL: root, storageFactory: { _ in storage })
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(storage.loadCount == 0)
        let first = record("Newest", id: .init(rawValue: "draft:first"))
        let stale = record("Stale", id: first.draftID)
        try await persistence.save(accountScope: "account_a", revision: 10, activeDraftID: first.draftID, drafts: [first])
        try await persistence.save(accountScope: "account_a", revision: 9, activeDraftID: first.draftID, drafts: [stale])
        try await persistence.save(accountScope: "account_a", revision: 10, activeDraftID: first.draftID, drafts: [stale])
        let restored = try #require(await persistence.load(accountScope: "account_a", followUpBehavior: .queue))
        #expect(restored.draft == "Newest")
        #expect(restored.followUpBehavior == .queue)
        #expect(storage.saved.count == 1)
    }

    @Test func failedWriteAllowsSameRevisionRetryAndDoesNotAdvancePastLastSuccess() async throws {
        let root = rootURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DraftPersistenceTestStorage()
        let persistence = CodexAppDraftPersistence(rootURL: root, storageFactory: { _ in storage })
        let first = record("First")
        try await persistence.save(accountScope: "account", revision: 1, activeDraftID: first.draftID, drafts: [first])
        let next = record("Next", id: first.draftID)
        storage.rejectNextSave()
        do {
            try await persistence.save(accountScope: "account", revision: 3, activeDraftID: next.draftID, drafts: [next])
            Issue.record("Expected the injected write to fail")
        } catch DraftPersistenceTestStorage.Failure.injected { }
        let afterFailure = try #require(await persistence.load(accountScope: "account", followUpBehavior: .steer))
        #expect(afterFailure.draft == "First")
        try await persistence.save(accountScope: "account", revision: 2, activeDraftID: next.draftID, drafts: [next])
        try await persistence.save(accountScope: "account", revision: 3, activeDraftID: next.draftID, drafts: [next])
        let retried = try #require(await persistence.load(accountScope: "account", followUpBehavior: .steer))
        #expect(retried.draft == "Next")
        #expect(storage.saved.count == 3)
    }

    @Test func accountsStoreSeparatelyWithIndependentRevisionCountersAndRestrictedNewFiles() async throws {
        let root = rootURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = CodexAppDraftPersistence(rootURL: root)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let first = record("Account A")
        let second = record("Account B")
        try await persistence.save(accountScope: "account_a", revision: 100, activeDraftID: first.draftID, drafts: [first])
        try await persistence.save(accountScope: "account_b", revision: 1, activeDraftID: second.draftID, drafts: [second])
        let a = try #require(await persistence.load(accountScope: "account_a", followUpBehavior: .queue))
        let b = try #require(await persistence.load(accountScope: "account_b", followUpBehavior: .steer))
        #expect(a.draft == "Account A")
        #expect(b.draft == "Account B")
        let rootMode = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("account_a.json").path)[.posixPermissions] as? NSNumber
        #expect(rootMode?.intValue == 0o700)
        #expect(fileMode?.intValue == 0o600)
    }

    @Test func existingRootPermissionsRemainUnchanged() async throws {
        let root = rootURL()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        let persistence = CodexAppDraftPersistence(rootURL: root)
        let draft = record("Saved")
        try await persistence.save(accountScope: "account", revision: 0, activeDraftID: draft.draftID, drafts: [draft])
        let mode = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o755)
    }

    @Test func corruptedLoadPreservesOriginalFileAndDoesNotMakeAnyWrite() async throws {
        let root = rootURL()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("account.json")
        let corrupt = Data("invalid composer JSON".utf8)
        try corrupt.write(to: url)
        let persistence = CodexAppDraftPersistence(rootURL: root)
        do {
            _ = try await persistence.load(accountScope: "account", followUpBehavior: .queue)
            Issue.record("Expected corrupt JSON to be rejected")
        } catch { }
        #expect(try Data(contentsOf: url) == corrupt)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["account.json"])
    }

    @Test func accountScopeValidationRejectsTraversalAndOversizedScopeBeforeStorageAccess() async throws {
        let root = rootURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DraftPersistenceTestStorage()
        let persistence = CodexAppDraftPersistence(rootURL: root, storageFactory: { _ in storage })
        let draft = record("Saved")
        for scope in ["", "../outside", "a/b", "a\\b", ".", "account\n", String(repeating: "a", count: 129)] {
            do {
                try await persistence.save(accountScope: scope, revision: 1, activeDraftID: draft.draftID, drafts: [draft])
                Issue.record("Invalid account scope was accepted")
            } catch let error as CodexComposerDraftStorageError {
                #expect(error == .invalidSnapshot("account scope"))
            }
        }
        #expect(storage.saved.isEmpty)
        #expect(storage.loadCount == 0)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func actorRoundTripRestoresFilesAnnotationsSkillsMentionsAndProjectMetadata() async throws {
        let root = rootURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = CodexAppDraftPersistence(rootURL: root)
        var composer = CodexComposerStateSession()
        let origin = composer.newDraft(workspacePath: "/repo", projectID: "opaque-project")
        composer.draft = "Inspect @Store.swift"
        let image = CodexReferencedFile(path: "/tmp/image.png", kind: .image)
        composer.referencedFiles = [image]
        let selection = CodexResponseTextAnnotation(id: "selection", text: "Prior response", annotation: "Explain",
            anchor: .init(renderItemID: "item", startOffset: 1, endOffset: 4))
        composer.responseAnnotations = [selection]
        let skill = CodexSlashCommand(id: "review", title: "Review", detail: "Review", systemImage: "hammer",
            skillName: "review", skillPath: "/skills/review/SKILL.md")
        composer.attachSkill(skill)
        composer.selectMention(.init(fileName: "Store.swift", matchType: .file, path: "Store.swift", root: "/repo", score: 1))
        let selected = composer.newDraft(workspacePath: "/other", isProjectless: true)
        composer.draft = "Other draft"
        try await persistence.save(accountScope: "account", revision: 1, activeDraftID: selected, drafts: composer.draftRecords)
        var restored = try #require(await persistence.load(accountScope: "account", followUpBehavior: .queue))
        #expect(restored.activeDraftID == selected)
        #expect(restored.draft == "Other draft")
        #expect(restored.draftRecords.first { $0.draftID == selected }?.isProjectless == true)
        restored.setActiveDraftID(origin)
        #expect(restored.referencedFiles == [image])
        #expect(restored.responseAnnotations == [selection])
        #expect(restored.attachedSkills == [skill])
        #expect(restored.draftRecords.first { $0.draftID == origin }?.projectID == "opaque-project")
        #expect(restored.consumeDraftForTurn()?.mentions == [.mention(name: "Store.swift", path: "/repo/Store.swift")])
    }
}

private final class DraftPersistenceTestStorage: CodexComposerDraftStorage, @unchecked Sendable {
    enum Failure: Error { case injected }
    private let lock = NSLock()
    private var snapshot: CodexComposerDraftsSnapshot?
    private var writes: [CodexComposerDraftsSnapshot] = []
    private var loads = 0
    private var rejectSave = false

    var saved: [CodexComposerDraftsSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return writes
    }
    var loadCount: Int {
        lock.lock(); defer { lock.unlock() }
        return loads
    }
    func rejectNextSave() {
        lock.lock(); defer { lock.unlock() }
        rejectSave = true
    }
    func load() throws -> CodexComposerDraftsSnapshot? {
        lock.lock(); defer { lock.unlock() }
        loads += 1
        return snapshot
    }
    func save(_ snapshot: CodexComposerDraftsSnapshot) throws {
        lock.lock(); defer { lock.unlock() }
        if rejectSave {
            rejectSave = false
            throw Failure.injected
        }
        self.snapshot = snapshot
        writes.append(snapshot)
    }
}
