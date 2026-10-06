import CodexCore
@testable import CodexCoreApp
@testable import CodexCoreUI
import CryptoKit
import Foundation
import Testing

@MainActor
struct CodexAppDraftRecoveryTests {
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

    private func makeModel(root: URL) -> CodexCoreAppModel {
        let model = CodexCoreAppModel(
            clipboardService: CodexNoopClipboardService(),
            preferenceStore: CodexNoopStringListPreferenceStore(),
            draftStorageDirectory: root
        )
        model.workspacePath = "/private/tmp/recovery-workspace"
        return model
    }

    private func prompts(_ model: CodexCoreAppModel) -> [String] {
        model.composerDraftRecords.map(\.prompt)
    }

    private func scope(_ identity: String) -> String {
        SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
