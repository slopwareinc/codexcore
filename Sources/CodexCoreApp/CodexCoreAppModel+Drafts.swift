import CryptoKit
import Foundation
import CodexCore
import CodexCoreUI

struct CodexComposerEditOrigin: Sendable {
    let draftID: CodexComposerDraftID
    let accountRevision: Int
    let scopeGeneration: UInt64
    let selectionGeneration: Int
    let workspacePath: String?
    let projectID: String?
    let isProjectless: Bool
}

@MainActor
extension CodexCoreAppModel {
    var composerDraftRecords: [CodexComposerDraftSnapshot] { composerSession.draftRecords }

    func startIndependentComposerDraft() {
        composerSession.newDraft(workspacePath: workspacePath,
                                 projectID: isProjectlessDraft ? nil : sidebarNavigationSession.selectedProjectID,
                                 isProjectless: isProjectlessDraft)
    }

    /// Capture ownership before accepting edits, rather than after navigation.
    func prepareComposerEdit() {
        syncComposerThreadID()
        if currentThreadID == nil, composerSession.activeDraftID == .unassigned,
           composerSession.activeDraftRecord.isEmpty {
            startIndependentComposerDraft()
            recordBootstrapPromotion()
        }
    }

    private func recordBootstrapPromotion() {
        bootstrapDraftIDsBySelectionGeneration[chatSelectionGeneration] = composerSession.activeDraftID
        if bootstrapDraftIDsBySelectionGeneration.count > CodexComposerDraftsSnapshot.maximumDrafts,
           let oldest = bootstrapDraftIDsBySelectionGeneration.keys.min() {
            bootstrapDraftIDsBySelectionGeneration.removeValue(forKey: oldest)
            expiredBootstrapSelectionGeneration = oldest
        }
    }

    var composerEditOrigin: CodexComposerEditOrigin {
        let record = composerSession.activeDraftRecord
        return .init(draftID: composerSession.activeDraftID, accountRevision: accountContextRevision,
              scopeGeneration: draftScopeGeneration, selectionGeneration: chatSelectionGeneration,
              workspacePath: record.workspacePath, projectID: record.projectID, isProjectless: record.isProjectless)
    }

    func composerDraftID(for origin: CodexComposerEditOrigin) -> CodexComposerDraftID? {
        guard origin.accountRevision == accountContextRevision, origin.scopeGeneration == draftScopeGeneration else { return nil }
        if origin.draftID == .unassigned, let expiredBootstrapSelectionGeneration,
           origin.selectionGeneration <= expiredBootstrapSelectionGeneration { return nil }
        let id = origin.draftID == .unassigned
            ? bootstrapDraftIDsBySelectionGeneration[origin.selectionGeneration] ?? origin.draftID : origin.draftID
        return composerSession.draftRecord(for: id) == nil ? nil : id
    }

    func addReferencedFileURLs(_ urls: [URL], to origin: CodexComposerEditOrigin) {
        guard var id = composerDraftID(for: origin) else { return }
        let references = urls.compactMap(CodexReferencedFile.fromDroppedURL)
        guard !references.isEmpty else { return }
        if id == .unassigned, id == composerSession.activeDraftID {
            prepareComposerEdit()
            id = composerSession.activeDraftID
        }
        if let record = composerSession.draftRecord(for: id), record.threadID == nil, record.isEmpty {
            composerSession.setDraftContext(workspacePath: origin.workspacePath, projectID: origin.projectID,
                                            isProjectless: origin.isProjectless, for: id)
        }
        composerSession.setReferencedFiles(composerSession.referencedFiles(for: id) + references, for: id)
    }

    private func mergeRecoveredComposerDrafts(_ restored: CodexComposerStateSession, restoreSelection: Bool = true) {
        let active = restored.draftRecords.first { $0.draftID == restored.activeDraftID }
        let sameWorkspace = active?.workspacePath.map(CodexProjectSummary.normalizedPath)
            == CodexProjectSummary.normalizedPath(workspacePath)
        let sameContext = active?.threadID == nil && active?.isProjectless == isProjectlessDraft
            && sameWorkspace && active?.projectID == sidebarNavigationSession.selectedProjectID
        // Legacy stored unassigned content must remain a card when the current
        // bootstrap represents another context; sharing its ID would activate it.
        if currentThreadID == nil, !sameContext, restored.activeDraftID == .unassigned,
           composerSession.activeDraftID == .unassigned, composerSession.draftRecords.allSatisfy(\.isEmpty) {
            startIndependentComposerDraft()
            recordBootstrapPromotion()
        }
        composerSession.mergeDrafts(from: restored,
                                   activateRestoredDraft: restoreSelection && currentThreadID == nil && sameContext)
    }

    func composerDraftsDidChange() {
        draftMutationRevision &+= 1
        guard draftStorageReady, let scope = draftAccountScope, draftPersistence != nil else { return }
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, !Task.isCancelled, draftAccountScope == scope else { return }
            await flushComposerDrafts()
        }
    }

    func flushComposerDrafts() async {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        guard draftStorageReady, let persistence = draftPersistence, let scope = draftAccountScope else { return }
        let generation = draftScopeGeneration
        let revision = draftMutationRevision
        let activeID = composerSession.activeDraftID
        let records = composerSession.draftRecords
        do {
            try await persistence.save(accountScope: scope, revision: revision, activeDraftID: activeID, drafts: records)
            guard draftAccountScope == scope, draftScopeGeneration == generation,
                  draftMutationRevision == revision else { return }
            draftPersistenceError = nil
            clearRecoveredDrafts(scope: scope, through: revision)
        } catch {
            guard draftAccountScope == scope, draftScopeGeneration == generation else { return }
            draftPersistenceError = "Could not save drafts. Your text is still in this session. \(error.localizedDescription)"
            retainRecoveredDrafts(scope: scope, revision: draftMutationRevision, session: composerSession)
        }
    }

    static func composerDraftAccountIdentity(authMode: String?, accountFields: [String: CodexJSONValue]?) -> String? {
        guard let authMode else { return nil }
        if authMode.lowercased() == "apikey" { return "apiKey-home" }
        if let email = CodexJSONCoercion.flatString(from: accountFields?["email"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !email.isEmpty { return "chatgpt-email:" + email.lowercased() }
        if let id = CodexJSONCoercion.flatString(from: accountFields?["accountId"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty { return "chatgpt-account:" + id }
        return nil
    }

    private func retainRecoveredDrafts(scope: String, revision: UInt64, session: CodexComposerStateSession) {
        guard revision >= (unsavedDraftRevisionByAccount[scope] ?? 0) else { return }
        unsavedDraftsByAccount[scope] = session
        unsavedDraftRevisionByAccount[scope] = revision
    }

    private func clearRecoveredDrafts(scope: String, through revision: UInt64) {
        guard let cached = unsavedDraftRevisionByAccount[scope], cached <= revision else { return }
        unsavedDraftsByAccount.removeValue(forKey: scope)
        unsavedDraftRevisionByAccount.removeValue(forKey: scope)
    }

    func bindComposerDraftAccount(identity: String?) {
        guard let persistence = draftPersistence else { return }
        let scope = identity.map { value in
            SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        guard scope != draftAccountScope else { return }
        bootstrapDraftIDsBySelectionGeneration.removeAll(keepingCapacity: true)
        expiredBootstrapSelectionGeneration = nil
        let previousScope = draftAccountScope
        if let previousScope {
            retainRecoveredDrafts(scope: previousScope, revision: draftMutationRevision, session: composerSession)
        }
        if let previousScope, draftStorageReady {
            let previousSession = composerSession
            let records = composerSession.draftRecords
            let activeID = composerSession.activeDraftID
            let revision = draftMutationRevision
            Task { [weak self] in
                do {
                    try await persistence.save(accountScope: previousScope, revision: revision,
                                               activeDraftID: activeID, drafts: records)
                    self?.clearRecoveredDrafts(scope: previousScope, through: revision)
                } catch {
                    guard let self else { return }
                    retainRecoveredDrafts(scope: previousScope, revision: revision, session: previousSession)
                    draftPersistenceError = "Could not save the previous account's drafts. They remain in this session; switch back to recover them. \(error.localizedDescription)"
                }
            }
        }
        draftSaveTask?.cancel()
        draftLoadTask?.cancel()
        draftScopeGeneration &+= 1
        draftStorageReady = false
        draftAccountScope = scope
        draftPersistenceError = nil
        if previousScope != nil {
            composerSession = CodexComposerStateSession(followUpBehavior: composerSession.followUpBehavior)
        }
        guard let scope else { isRestoringDrafts = false; return }
        loadComposerDrafts(scope: scope)
    }

    private func loadComposerDrafts(scope: String) {
        guard let persistence = draftPersistence else { return }
        if let recovered = unsavedDraftsByAccount[scope] {
            mergeRecoveredComposerDrafts(recovered)
        }
        let generation = draftScopeGeneration
        let behavior = composerSession.followUpBehavior
        isRestoringDrafts = true
        draftLoadTask = Task { [weak self] in
            do {
                let restored = try await persistence.load(accountScope: scope, followUpBehavior: behavior)
                guard let self, !Task.isCancelled, draftAccountScope == scope,
                      draftScopeGeneration == generation else { return }
                if let restored {
                    mergeRecoveredComposerDrafts(restored)
                    if currentThreadID != nil { composerSession.setActiveThreadID(currentThreadID) }
                }
                if let unsaved = unsavedDraftsByAccount[scope] {
                    mergeRecoveredComposerDrafts(unsaved, restoreSelection: false)
                }
                draftStorageReady = true
                isRestoringDrafts = false
                draftPersistenceError = nil
                composerDraftsDidChange()
            } catch {
                guard let self, !Task.isCancelled, draftAccountScope == scope,
                      draftScopeGeneration == generation else { return }
                isRestoringDrafts = false
                // Preserve unreadable files; typing must not silently overwrite recovery data.
                draftStorageReady = false
                draftPersistenceError = "Could not load saved drafts. Automatic saving is paused; your current text is kept in this session. \(error.localizedDescription)"
            }
        }
    }

    func retryComposerDraftPersistence() {
        if draftStorageReady { Task { await flushComposerDrafts() } }
        else if let scope = draftAccountScope { loadComposerDrafts(scope: scope) }
    }

    func selectComposerDraft(_ draftID: CodexComposerDraftID) async {
        guard let record = composerSession.draftRecords.first(where: { $0.draftID == draftID }) else { return }
        let revision = accountContextRevision
        let provider = codex
        if let threadID = record.threadID {
            applyComposerDraftWorkspace(record)
            await resumeChat(id: threadID)
            guard codex === provider, revision == accountContextRevision, currentThreadID == threadID else { return }
            applyComposerDraftWorkspace(record)
            composerSession.setActiveDraftID(draftID, threadID: threadID)
            return
        }
        activateComposerDraft(record)
        await refreshRecentChats()
    }

    func discardComposerDraft(_ draftID: CodexComposerDraftID) {
        let discardingActiveDraft = draftID == composerSession.activeDraftID
        composerSession.discardDraft(draftID)
        if discardingActiveDraft { startIndependentComposerDraft() }
    }
}
