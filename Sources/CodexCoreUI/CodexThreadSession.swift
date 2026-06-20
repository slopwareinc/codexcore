import Foundation
import CodexCore

public struct CodexThreadLaunchConfiguration: Equatable, Sendable {
    public var approvalMode: ApprovalMode
    public var cwd: String
    public var modelIdentifier: String?
    public var sandbox: Sandbox
    public var dynamicTools: [CodexDynamicToolSpec]?

    public init(
        approvalMode: ApprovalMode,
        cwd: String,
        modelIdentifier: String?,
        sandbox: Sandbox,
        dynamicTools: [CodexDynamicToolSpec]? = nil
    ) {
        self.approvalMode = approvalMode
        self.cwd = cwd
        self.modelIdentifier = modelIdentifier
        self.sandbox = sandbox
        self.dynamicTools = dynamicTools
    }
}

public struct CodexEnsuredThread {
    public var thread: CodexThread
    public var didStart: Bool

    public init(thread: CodexThread, didStart: Bool) {
        self.thread = thread
        self.didStart = didStart
    }
}

public struct CodexEnsuredSideChatThread {
    public var thread: CodexThread
    public var didFork: Bool

    public init(thread: CodexThread, didFork: Bool) {
        self.thread = thread
        self.didFork = didFork
    }
}

@MainActor
public final class CodexThreadSession {
    public private(set) var currentThread: CodexThread?
    public private(set) var sideChatThread: CodexThread?

    public init() {}

    public var isThreadReady: Bool {
        currentThread != nil
    }

    public var currentThreadID: String? {
        currentThread?.id
    }

    public func isCurrentThread(id threadID: String) -> Bool {
        currentThread?.id == threadID
    }

    public func reset() {
        currentThread = nil
        sideChatThread = nil
    }

    public func ensureThread(
        using codex: Codex,
        configuration: CodexThreadLaunchConfiguration
    ) async throws -> CodexEnsuredThread {
        if let currentThread {
            return CodexEnsuredThread(thread: currentThread, didStart: false)
        }

        let thread = try await codex.threadStart(
            approvalMode: configuration.approvalMode,
            cwd: configuration.cwd,
            dynamicTools: configuration.dynamicTools,
            model: configuration.modelIdentifier,
            sandbox: configuration.sandbox
        )
        currentThread = thread
        return CodexEnsuredThread(thread: thread, didStart: true)
    }

    public func resumeThread(
        id threadID: String,
        using codex: Codex,
        configuration: CodexThreadLaunchConfiguration
    ) async throws -> CodexThread {
        reset()
        let thread = try await codex.threadResume(
            threadID,
            approvalMode: configuration.approvalMode,
            cwd: configuration.cwd,
            model: configuration.modelIdentifier,
            sandbox: configuration.sandbox
        )
        currentThread = thread
        return thread
    }

    public func forkCurrentThread(
        using codex: Codex,
        configuration: CodexThreadLaunchConfiguration
    ) async throws -> (sourceID: String, thread: CodexThread)? {
        guard let currentThread else { return nil }
        let sourceID = currentThread.id
        let thread = try await codex.threadFork(
            sourceID,
            approvalMode: configuration.approvalMode,
            cwd: configuration.cwd,
            ephemeral: false,
            model: configuration.modelIdentifier,
            sandbox: configuration.sandbox
        )
        reset()
        self.currentThread = thread
        return (sourceID, thread)
    }

    public func archiveCurrentThread(using codex: Codex) async throws -> String? {
        guard let currentThread else { return nil }
        let archivedID = currentThread.id
        _ = try await codex.threadArchive(archivedID)
        reset()
        return archivedID
    }

    public func ensureSideChatThread(
        using codex: Codex,
        configuration: CodexThreadLaunchConfiguration
    ) async throws -> CodexEnsuredSideChatThread {
        if let sideChatThread {
            return CodexEnsuredSideChatThread(thread: sideChatThread, didFork: false)
        }

        let parent = try await ensureThread(using: codex, configuration: configuration).thread
        let forked = try await codex.threadFork(
            parent.id,
            approvalMode: configuration.approvalMode,
            cwd: configuration.cwd,
            ephemeral: true,
            model: configuration.modelIdentifier,
            sandbox: configuration.sandbox
        )
        sideChatThread = forked
        return CodexEnsuredSideChatThread(thread: forked, didFork: true)
    }
}
