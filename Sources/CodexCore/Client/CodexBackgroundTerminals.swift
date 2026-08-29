import Foundation

/// Server-owned background terminal operations. These methods use only the
/// generated `thread/backgroundTerminals/*` requests and return the canonical
/// process state installed by those responses.
public extension CodexSession {
    func listBackgroundTerminals(
        threadID: ThreadID,
        limit: Int? = 100
    ) async throws -> CanonicalBackgroundTerminalState {
        var cursor: String?
        var seenCursors: Set<String> = []
        while true {
            let response = try await perform(CodexRequest.threadBackgroundTerminalsList(.init(
                cursor: cursor,
                limit: limit,
                threadID: threadID.rawValue
            )))
            guard let nextCursor = response.nextCursor else { break }
            guard seenCursors.insert(nextCursor).inserted else {
                throw CodexSessionError.protocolViolation(
                    "thread/backgroundTerminals/list repeated cursor \(nextCursor)"
                )
            }
            cursor = nextCursor
        }
        return canonicalSnapshot(
            scope: .thread(threadID, fields: .backgroundTerminals)
        ).backgroundTerminals[threadID]
            ?? CanonicalBackgroundTerminalState(threadID: threadID)
    }

    @discardableResult
    func terminateBackgroundTerminal(
        threadID: ThreadID,
        processID: String
    ) async throws -> Bool {
        let response = try await perform(CodexRequest.threadBackgroundTerminalsTerminate(.init(
            processID: processID,
            threadID: threadID.rawValue
        )))
        return response.terminated
    }

    func cleanBackgroundTerminals(threadID: ThreadID) async throws {
        _ = try await perform(CodexRequest.threadBackgroundTerminalsClean(.init(
            threadID: threadID.rawValue
        )))
    }
}

public extension Codex {
    func listBackgroundTerminals(
        threadID: ThreadID,
        limit: Int? = 100
    ) async throws -> CanonicalBackgroundTerminalState {
        try await session.listBackgroundTerminals(threadID: threadID, limit: limit)
    }

    @discardableResult
    func terminateBackgroundTerminal(
        threadID: ThreadID,
        processID: String
    ) async throws -> Bool {
        try await session.terminateBackgroundTerminal(
            threadID: threadID,
            processID: processID
        )
    }

    func cleanBackgroundTerminals(threadID: ThreadID) async throws {
        try await session.cleanBackgroundTerminals(threadID: threadID)
    }
}
