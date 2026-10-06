import Foundation
import CodexCoreUI

/// Keeps encoding and filesystem work away from the reference host's main actor.
actor CodexAppDraftPersistence {
    typealias StorageFactory = @Sendable (URL) -> any CodexComposerDraftStorage

    private let rootURL: URL
    private let storageFactory: StorageFactory
    private var lastSavedRevisionByScope: [String: UInt64] = [:]

    init(
        rootURL: URL,
        storageFactory: @escaping StorageFactory = { CodexComposerDraftFileStorage(fileURL: $0) }
    ) {
        self.rootURL = rootURL
        self.storageFactory = storageFactory
    }

    func load(
        accountScope: String,
        followUpBehavior: CodexFollowUpBehavior
    ) throws -> CodexComposerStateSession? {
        let storage = storageFactory(try fileURL(accountScope: accountScope))
        guard let snapshot = try storage.load() else { return nil }
        return try CodexComposerStateSession(restoring: snapshot, followUpBehavior: followUpBehavior)
    }

    /// A failed write leaves its revision retryable; successful older/equal writes are idempotent.
    func save(
        accountScope: String,
        revision: UInt64,
        activeDraftID: CodexComposerDraftID,
        drafts: [CodexComposerDraftSnapshot]
    ) throws {
        let url = try fileURL(accountScope: accountScope)
        if let savedRevision = lastSavedRevisionByScope[accountScope], revision <= savedRevision { return }
        let snapshot = try CodexComposerDraftsSnapshot(activeDraftID: activeDraftID, drafts: drafts)
        // Reject oversized data before creating storage directories or touching the existing file.
        _ = try snapshot.encoded()
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try storageFactory(url).save(snapshot)
        lastSavedRevisionByScope[accountScope] = revision
    }

    private func fileURL(accountScope: String) throws -> URL {
        guard rootURL.isFileURL, rootURL.path.hasPrefix("/") else {
            throw CodexComposerDraftStorageError.invalidSnapshot("draft storage root")
        }
        guard !accountScope.isEmpty, accountScope.utf8.count <= 128,
              accountScope.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                      || byte == 45 || byte == 95
              }) else {
            throw CodexComposerDraftStorageError.invalidSnapshot("account scope")
        }
        return rootURL.appendingPathComponent(accountScope + ".json", isDirectory: false)
    }
}
