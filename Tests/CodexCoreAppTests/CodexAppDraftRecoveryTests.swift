import CodexCore
@testable import CodexCoreApp
@testable import CodexCoreUI
import CryptoKit
import Foundation
import Testing

@MainActor
struct CodexAppDraftRecoveryTests {
    @Test func changingLocalProjectPrimaryFolderPreservesItsUnsentDraft() async throws {
        let model = CodexCoreAppModel()
        let source = "/private/tmp/local-draft-source"
        let destination = "/private/tmp/local-draft-destination"
        model.workspacePath = source
        model.isProjectlessDraft = false
        model.sidebarNavigationSession.selectProject(source, workspacePath: source)
        model.draft = "Work in the original folder"
        let origin = model.composerSession.activeDraftRecord

        await model.updateSidebarProject(.init(workspacePath: source), displayName: "Updated project",
                                         sourceFolders: [destination, source])

        #expect(model.composerSession.draftRecord(for: origin.draftID) == origin)
        #expect(model.composerSession.activeDraftID != origin.draftID)
        #expect(model.draft.isEmpty)
        #expect(model.workspacePath == destination)
        #expect(model.composerSession.activeDraftRecord.workspacePath == destination)
        #expect(model.composerSession.activeDraftRecord.projectID == destination)
        #expect(model.threadStartParameters().cwd == destination)
    }

    @Test(arguments: ["skill", "mention", "prompt"])
    func firstContextEditDuringLegacyRecoveryOwnsAnIndependentDraft(kind: String) async throws {
        let root = temporaryRoot()
        let model = makeModel(root: root)
        defer {
            model.draftSaveTask?.cancel()
            model.draftLoadTask?.cancel()
            try? FileManager.default.removeItem(at: root)
        }
        var saved = CodexComposerStateSession()
        saved.setActiveDraftID(.unassigned, workspacePath: "/private/tmp/previous-project", projectID: "previous-project", isProjectless: false)
        saved.draft = "Legacy saved prompt"
        try CodexComposerDraftFileStorage(fileURL: root.appendingPathComponent(scope("A") + ".json"))
            .save(saved.draftSnapshot())
        model.bindComposerDraftAccount(identity: "A")
        #expect(model.isRestoringDrafts)

        switch kind {
        case "skill":
            model.handleSlashCommand(.init(id: "skill:first", title: "First skill", detail: "Synthetic skill",
                                          systemImage: "shippingbox", skillName: "first", skillPath: "/private/tmp/first/SKILL.md"))
        case "mention":
            model.selectMention(.init(fileName: "Current.swift", matchType: .file, path: "Current.swift", root: model.workspacePath, score: 1))
        default:
            model.handleSlashCommand(.init(id: "custom:first", title: "First prompt", detail: "Synthetic prompt",
                                          systemImage: "text.bubble", draftText: "Current custom prompt"))
        }
        let currentID = model.composerSession.activeDraftID
        #expect(currentID != .unassigned)
        await model.draftLoadTask?.value

        #expect(model.composerSession.activeDraftID == currentID)
        #expect(model.composerSession.activeDraftRecord.workspacePath == model.workspacePath)
        #expect(model.composerSession.activeDraftRecord.isProjectless)
        #expect(!model.draft.contains("Legacy saved prompt"))
        #expect(model.composerDraftRecords.first { $0.draftID == .unassigned }?.prompt == "Legacy saved prompt")
        if kind == "skill" {
            #expect(model.draft.isEmpty)
            #expect(model.composerSession.activeDraftRecord.attachedSkills.map(\.skillName) == ["first"])
        } else if kind == "mention" {
            #expect(model.composerSession.activeDraftRecord.selectedMentions.map(\.fileName) == ["Current.swift"])
        } else {
            #expect(model.draft == "Current custom prompt")
        }
    }

    @Test func menuOnlySlashCommandsLeaveTheBootstrapSelectionPristine() {
        let model = CodexCoreAppModel()
        for id in ["model", "reasoning", "status"] {
            model.handleSlashCommand(.init(id: id, title: id, detail: "Menu command", systemImage: "gear",
                                          draftText: "Ignored by this host-only command"))
            #expect(model.composerSession.activeDraftID == .unassigned)
            #expect(model.composerSession.activeDraftRecord.isEmpty)
        }
    }

    @Test func legacyRecoveryDoesNotStealAPendingBootstrapAttachment() async throws {
        let root = temporaryRoot()
        let model = makeModel(root: root)
        let file = try attachmentFile("recovery-drop.png")
        defer {
            model.draftSaveTask?.cancel()
            model.draftLoadTask?.cancel()
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        var saved = CodexComposerStateSession()
        saved.setActiveDraftID(.unassigned, workspacePath: "/private/tmp/previous-project", projectID: "previous-project", isProjectless: false)
        saved.draft = "Legacy saved prompt"
        try CodexComposerDraftFileStorage(fileURL: root.appendingPathComponent(scope("A") + ".json"))
            .save(saved.draftSnapshot())
        model.bindComposerDraftAccount(identity: "A")
        let origin = model.composerEditOrigin
        await model.draftLoadTask?.value
        let currentID = model.composerSession.activeDraftID

        model.addReferencedFileURLs([file], to: origin)

        #expect(model.composerSession.activeDraftID == currentID)
        #expect(model.composerSession.activeDraftRecord.workspacePath == model.workspacePath)
        #expect(model.referencedFiles.map(\.path) == [file.path])
        #expect(model.composerSession.draftRecord(for: .unassigned)?.referencedFiles.isEmpty == true)
    }

    @Test(arguments: [false, true])
    func delayedBootstrapAttachmentFollowsTheFirstEditIdentityAfterNavigation(navigate: Bool) async throws {
        let model = CodexCoreAppModel()
        let file = try attachmentFile("delayed.png")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let origin = model.composerEditOrigin
        #expect(origin.draftID == .unassigned)
        model.draft = "Draft A typed after drop started"
        let draftA = model.composerSession.activeDraftID
        if navigate { await model.startNewChat() }

        model.addReferencedFileURLs([file], to: origin)

        let original = try #require(model.composerSession.draftRecord(for: draftA))
        #expect(original.referencedFiles.map(\.path) == [file.path])
        if navigate {
            #expect(model.composerSession.activeDraftID != draftA)
            #expect(model.referencedFiles.isEmpty)
        } else {
            #expect(model.composerSession.activeDraftID == draftA)
            #expect(model.referencedFiles.map(\.path) == [file.path])
        }
    }

    @Test func delayedAttachmentUsesTheOriginalDraftAfterNativePromotion() async throws {
        let model = CodexCoreAppModel()
        let file = try attachmentFile("promoted.png")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        model.draft = "Original A"
        let draftA = model.composerSession.activeDraftID
        let origin = model.composerEditOrigin
        model.composerSession.promoteDraft(draftA, to: "native-a")
        await model.startNewChat()

        model.addReferencedFileURLs([file], to: origin)

        let promoted = try #require(model.composerSession.draftRecord(for: draftA))
        #expect(promoted.threadID == "native-a")
        #expect(promoted.referencedFiles.map(\.path) == [file.path])
        #expect(model.referencedFiles.isEmpty)
    }

    @Test func imageOnlyBootstrapDropRetainsCapturedContextAfterStartingAProjectChat() async throws {
        let model = CodexCoreAppModel()
        let file = try attachmentFile("image-only.png")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let originalWorkspace = model.workspacePath
        let origin = model.composerEditOrigin
        installProjects([project(id: "destination-project", path: originalWorkspace)], in: model)
        await model.startNewChat(inProject: "destination-project")
        let destinationID = model.composerSession.activeDraftID

        model.addReferencedFileURLs([file], to: origin)

        #expect(model.composerSession.activeDraftID == destinationID)
        #expect(model.referencedFiles.isEmpty)
        let original = try #require(model.composerSession.draftRecord(for: origin.draftID))
        #expect(original.workspacePath == originalWorkspace)
        #expect(original.isProjectless)
        #expect(original.projectID == nil)
        #expect(original.referencedFiles.map(\.path) == [file.path])
    }

    @Test func discardedOrChangedAccountAttachmentOriginsAreRejected() async throws {
        let root = temporaryRoot()
        let model = makeModel(root: root)
        let file = try attachmentFile("rejected.png")
        defer {
            model.draftSaveTask?.cancel()
            model.draftLoadTask?.cancel()
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        model.draft = "Discarded original"
        let discardedOrigin = model.composerEditOrigin
        model.discardComposerDraft(discardedOrigin.draftID)
        model.addReferencedFileURLs([file], to: discardedOrigin)
        #expect(model.composerSession.draftRecord(for: discardedOrigin.draftID) == nil)
        #expect(model.referencedFiles.isEmpty)

        model.bindComposerDraftAccount(identity: "A")
        await model.draftLoadTask?.value
        model.draft = "Account A original"
        let accountOrigin = model.composerEditOrigin
        model.bindComposerDraftAccount(identity: "B")
        await model.draftLoadTask?.value
        model.addReferencedFileURLs([file], to: accountOrigin)
        model.applyDictationCompletion(.init(text: "Rejected dictation", action: .insert), origin: accountOrigin)
        #expect(model.referencedFiles.isEmpty)
        #expect(model.draft.isEmpty)
        #expect(model.composerDraftRecords.allSatisfy { $0.referencedFiles.isEmpty })
    }

    @Test func initialHomeDraftKeepsProjectlessOwnershipWhenStartingAProjectChat() async throws {
        let model = CodexCoreAppModel()
        let initialWorkspace = model.workspacePath
        #expect(model.isProjectlessDraft)
        #expect(model.composerSession.activeDraftID == .unassigned)
        model.draft = "Initial projectless draft"
        let originID = model.composerSession.activeDraftID
        #expect(originID != .unassigned)
        installProjects([project(id: "home-project", path: initialWorkspace)], in: model)

        await model.startNewChat(inProject: "home-project")

        let origin = try #require(model.composerDraftRecords.first { $0.draftID == originID })
        #expect(origin.prompt == "Initial projectless draft")
        #expect(origin.workspacePath == initialWorkspace)
        #expect(origin.projectID == nil)
        #expect(origin.isProjectless)
        let destination = try #require(model.composerDraftRecords.first { $0.draftID == model.composerSession.activeDraftID })
        #expect(destination.draftID != originID)
        #expect(destination.projectID == "home-project")
        #expect(!destination.isProjectless)
    }

    @Test(arguments: [false, true])
    func selectingAnotherProjectPreservesOriginEvenWhenFoldersAreShared(differentFolder: Bool) async throws {
        let model = CodexCoreAppModel()
        let pathA = "/private/tmp/draft-context-a"
        let pathB = differentFolder ? "/private/tmp/draft-context-b" : pathA
        model.workspacePath = pathA
        model.isProjectlessDraft = false
        model.sidebarNavigationSession.selectProject("project-a", workspacePath: pathA)
        installProjects([project(id: "project-a", path: pathA), project(id: "project-b", path: pathB)], in: model)
        model.draft = "Project A unsent text"
        let originID = model.composerSession.activeDraftID

        await model.selectSidebarProject("project-b")

        let origin = try #require(model.composerDraftRecords.first { $0.draftID == originID })
        #expect(origin.prompt == "Project A unsent text")
        #expect(origin.workspacePath == pathA)
        #expect(origin.projectID == "project-a")
        #expect(!origin.isProjectless)
        #expect(model.composerSession.activeDraftID != originID)
        #expect(model.draft.isEmpty)
        #expect(model.workspacePath == pathB)
        let destination = try #require(model.composerDraftRecords.first { $0.draftID == model.composerSession.activeDraftID })
        #expect(destination.projectID == "project-b")
        #expect(destination.workspacePath == pathB)
    }

    @Test func automationNewChatPreservesTheOriginalTextAndAttachments() async throws {
        let model = CodexCoreAppModel()
        model.draft = "Original draft"
        model.referencedFiles = [.init(path: "/private/tmp/original.png", kind: .image)]
        let origin = try #require(model.composerDraftRecords.first { $0.draftID == model.composerSession.activeDraftID })

        await model.prepareAutomationDraft(.init(prompt: "Create a scheduled task", activityTitle: "Create",
                                                activityDetail: "Synthetic task", startsNewChat: true))

        #expect(model.composerDraftRecords.first { $0.draftID == origin.draftID } == origin)
        #expect(model.composerSession.activeDraftID != origin.draftID)
        #expect(model.draft == "Create a scheduled task")
        #expect(model.referencedFiles.isEmpty)
    }

    @Test func discardingTheActiveDraftDoesNotSelectLegacyTextUnderAnotherWorkspace() async throws {
        let model = CodexCoreAppModel()
        model.composerSession.setActiveDraftID(.unassigned, workspacePath: "/private/tmp/legacy-a", projectID: "project-a", isProjectless: false)
        model.composerSession.draft = "Legacy A text"
        model.workspacePath = "/private/tmp/active-b"
        model.isProjectlessDraft = false
        model.sidebarNavigationSession.selectProject("project-b", workspacePath: model.workspacePath)
        model.startIndependentComposerDraft()
        model.draft = "Draft B text"
        let discardedID = model.composerSession.activeDraftID

        model.discardComposerDraft(discardedID)

        #expect(model.draft.isEmpty)
        #expect(model.composerSession.activeDraftID != .unassigned)
        #expect(model.composerSession.activeDraftID != discardedID)
        let current = try #require(model.composerDraftRecords.first { $0.draftID == model.composerSession.activeDraftID })
        #expect(current.workspacePath == "/private/tmp/active-b")
        #expect(current.projectID == "project-b")
        #expect(model.composerDraftRecords.first { $0.draftID == .unassigned }?.prompt == "Legacy A text")
    }

    @Test func explicitEmptyNewChatDuringLoadingRetainsItsSelection() async throws {
        let root = temporaryRoot()
        let model = makeModel(root: root)
        defer {
            model.draftSaveTask?.cancel(); model.draftLoadTask?.cancel()
            try? FileManager.default.removeItem(at: root)
        }
        var persisted = CodexComposerStateSession()
        let savedID = persisted.newDraft(workspacePath: model.workspacePath, isProjectless: true)
        persisted.draft = "Saved selection"
        try CodexComposerDraftFileStorage(fileURL: root.appendingPathComponent(scope("A") + ".json"))
            .save(persisted.draftSnapshot())
        model.bindComposerDraftAccount(identity: "A")
        #expect(model.isRestoringDrafts)

        await model.startNewChat()
        let explicitID = model.composerSession.activeDraftID
        await model.draftLoadTask?.value

        #expect(model.composerSession.activeDraftID == explicitID)
        #expect(model.draft.isEmpty)
        #expect(model.composerDraftRecords.first { $0.draftID == savedID }?.prompt == "Saved selection")
    }

    @Test func mismatchedCachedLegacyDraftStaysInactiveUntilItsCardIsSelected() async throws {
        let root = temporaryRoot()
        let model = makeModel(root: root)
        defer {
            model.draftSaveTask?.cancel(); model.draftLoadTask?.cancel()
            try? FileManager.default.removeItem(at: root)
        }
        var recovered = CodexComposerStateSession()
        recovered.setActiveDraftID(.unassigned, workspacePath: "/private/tmp/account-a-workspace",
                                   projectID: "project-a", isProjectless: false)
        recovered.draft = "Account A recovered text"
        model.unsavedDraftsByAccount[scope("A")] = recovered
        model.workspacePath = "/private/tmp/account-b-workspace"
        model.isProjectlessDraft = false
        model.sidebarNavigationSession.selectProject("project-b", workspacePath: model.workspacePath)

        model.bindComposerDraftAccount(identity: "A")
        await model.draftLoadTask?.value

        #expect(model.draft.isEmpty)
        #expect(model.composerSession.activeDraftID != .unassigned)
        #expect(model.workspacePath == "/private/tmp/account-b-workspace")
        #expect(model.sidebarNavigationSession.selectedProjectID == "project-b")
        #expect(model.composerDraftRecords.first { $0.draftID == .unassigned }?.prompt == "Account A recovered text")
        await model.selectComposerDraft(.unassigned)
        #expect(model.draft == "Account A recovered text")
        #expect(model.workspacePath == "/private/tmp/account-a-workspace")
        #expect(model.sidebarNavigationSession.selectedProjectID == "project-a")
    }

    @Test func accountSwitchDuringInitialLoadRetainsTypingWithoutShowingItInAnotherAccount() async throws {
        let root = temporaryRoot()
        let model = makeModel(root: root)
        defer {
            model.draftSaveTask?.cancel()
            model.draftLoadTask?.cancel()
            try? FileManager.default.removeItem(at: root)
        }

        // No suspension before binding B: A's queued load cannot run between
        // binding the account, typing, and leaving it.
        model.bindComposerDraftAccount(identity: "A")
        #expect(model.isRestoringDrafts)
        #expect(!model.draftStorageReady)
        model.draft = "Account A typed during loading"
        model.bindComposerDraftAccount(identity: "B")
        #expect(!prompts(model).contains("Account A typed during loading"))

        await model.draftLoadTask?.value
        model.draft = "Account B draft"
        await model.flushComposerDrafts()

        model.bindComposerDraftAccount(identity: "A")
        await model.draftLoadTask?.value
        #expect(prompts(model).contains("Account A typed during loading"))
        #expect(!prompts(model).contains("Account B draft"))

        model.bindComposerDraftAccount(identity: "B")
        await model.draftLoadTask?.value
        #expect(prompts(model).contains("Account B draft"))
        #expect(!prompts(model).contains("Account A typed during loading"))
        await model.flushComposerDrafts()
    }

    @Test func unreadableAccountFileRetainsRecoveryDraftAcrossNavigationWithoutOverwritingBytes() async throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let accountFile = root.appendingPathComponent(scope("A") + ".json")
        let unreadable = Data("Unreadable composer snapshot".utf8)
        try unreadable.write(to: accountFile)
        let model = makeModel(root: root)
        defer {
            model.draftSaveTask?.cancel()
            model.draftLoadTask?.cancel()
            try? FileManager.default.removeItem(at: root)
        }

        model.bindComposerDraftAccount(identity: "A")
        await model.draftLoadTask?.value
        #expect(!model.draftStorageReady)
        #expect(model.draftPersistenceError != nil)
        model.draft = "Account A recovery draft"

        model.bindComposerDraftAccount(identity: "B")
        await model.draftLoadTask?.value
        #expect(!prompts(model).contains("Account A recovery draft"))
        model.draft = "Account B draft"
        await model.flushComposerDrafts()

        model.bindComposerDraftAccount(identity: "A")
        await model.draftLoadTask?.value
        #expect(prompts(model).contains("Account A recovery draft"))
        #expect(!prompts(model).contains("Account B draft"))
        #expect(!model.draftStorageReady)
        #expect(model.draftPersistenceError != nil)
        #expect(!model.isRestoringDrafts)
        await model.flushComposerDrafts()
        #expect(try Data(contentsOf: accountFile) == unreadable)

        model.bindComposerDraftAccount(identity: "B")
        await model.draftLoadTask?.value
        #expect(prompts(model).contains("Account B draft"))
        #expect(!prompts(model).contains("Account A recovery draft"))
        #expect(try Data(contentsOf: accountFile) == unreadable)
        await model.flushComposerDrafts()
    }

    @Test func draftAccountIdentityRequiresConfirmedChatGPTIdentityAndDefinesAPIKeyHomeScope() throws {
        #expect(CodexCoreAppModel.composerDraftAccountIdentity(authMode: nil, accountFields: nil) == nil)
        #expect(CodexCoreAppModel.composerDraftAccountIdentity(authMode: nil, accountFields: [
            "email": .string("person@example.com"),
        ]) == nil)
        #expect(CodexCoreAppModel.composerDraftAccountIdentity(authMode: "chatgpt", accountFields: nil) == nil)
        #expect(CodexCoreAppModel.composerDraftAccountIdentity(authMode: "chatgpt", accountFields: [
            "email": .string(" \n\t "), "accountId": .string(" "),
        ]) == nil)

        let normalizedEmail = try #require(CodexCoreAppModel.composerDraftAccountIdentity(
            authMode: "chatgpt", accountFields: ["email": .string("person@example.com")]
        ))
        let emailWithFormatting = CodexCoreAppModel.composerDraftAccountIdentity(
            authMode: "chatgpt", accountFields: [
                "email": .string("  Person@Example.Com\n"), "accountId": .string("irrelevant-account-id"),
            ]
        )
        #expect(normalizedEmail == emailWithFormatting)
        #expect(normalizedEmail == CodexCoreAppModel.composerDraftAccountIdentity(
            authMode: "chatgptAuthTokens", accountFields: ["email": .string("person@example.com")]
        ))
        #expect(normalizedEmail != CodexCoreAppModel.composerDraftAccountIdentity(
            authMode: "chatgpt", accountFields: ["email": .string("another@example.com")]
        ))

        let accountID = try #require(CodexCoreAppModel.composerDraftAccountIdentity(
            authMode: "chatgpt", accountFields: ["accountId": .string("account-id")]
        ))
        #expect(accountID == CodexCoreAppModel.composerDraftAccountIdentity(
            authMode: "chatgpt", accountFields: ["accountId": .string(" account-id ")]
        ))
        #expect(accountID != normalizedEmail)
        #expect(CodexCoreAppModel.composerDraftAccountIdentity(authMode: "apiKey", accountFields: nil) == "apiKey-home")
        #expect(CodexCoreAppModel.composerDraftAccountIdentity(authMode: "apiKey", accountFields: [
            "email": .string("ignored@example.com"),
        ]) == "apiKey-home")
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("codex-app-draft-recovery-\(UUID())", isDirectory: true)
    }

    private func attachmentFile(_ name: String) throws -> URL {
        let directory = temporaryRoot()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try Data().write(to: file)
        return file.standardizedFileURL
    }

    private func installProjects(_ projects: [CodexSchemaProject], in model: CodexCoreAppModel) {
        model.threadListSession.applyProjectList(.init(data: projects))
    }

    private func project(id: String, path: String) -> CodexSchemaProject {
        .init(createdAt: 1, id: id, metadata: [:], name: id, position: 0,
              roots: [.init(path: .init(.string(path)))], updatedAt: 1)
    }

    private func makeModel(root: URL) -> CodexCoreAppModel {
        let model = CodexCoreAppModel(
            clipboardService: CodexNoopClipboardService(),
            preferenceStore: CodexNoopStringListPreferenceStore(),
            draftStorageDirectory: root
        )
        model.workspacePath = "/private/tmp/recovery-workspace"
        model.syncComposerThreadID()
        return model
    }

    private func prompts(_ model: CodexCoreAppModel) -> [String] {
        model.composerDraftRecords.map(\.prompt)
    }

    private func scope(_ identity: String) -> String {
        SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
