import Foundation

/// The protocol identity of an auxiliary operation, without its connection epoch.
///
/// Correlations are intentionally explicit. There is no catch-all notification key:
/// consumers must opt into one operation family and one protocol identity.
public enum CodexOperationCorrelation: Sendable, Hashable {
    case skills
    case hook(threadID: String, runID: String)
    case commandExec(processID: String)
    case process(handle: String)
    case fuzzyFileSearch(sessionID: String)
    case realtime(threadID: String)
    case mcpServerStartup(name: String, threadID: String?)
    case mcpServerOAuth(name: String, threadID: String?)
    case applications
    case remoteControl(installationID: String)
    case externalAgentConfigImport(importID: String)
    case fileSystemWatch(watchID: String)
    case windowsSandbox(mode: String)
    case accountLogin(loginID: String?)
}

/// Exact identity for one auxiliary operation on one physical connection.
///
/// Epoch scoping prevents a late notification from an obsolete transport from
/// satisfying a channel registered after reconnect.
public struct CodexOperationKey: Sendable, Hashable {
    public let connectionEpoch: UInt64
    public let correlation: CodexOperationCorrelation

    public init(
        connectionEpoch: UInt64,
        correlation: CodexOperationCorrelation
    ) {
        self.connectionEpoch = connectionEpoch
        self.correlation = correlation
    }
}

/// Typed payloads for every notification that `ProtocolStateAdapter` can classify
/// as an auxiliary operation.
public enum CodexOperationEventPayload: Sendable, Equatable {
    case skillsChanged(CodexSchemaSkillsChangedNotification)
    case hookStarted(CodexSchemaHookStartedNotification)
    case hookCompleted(CodexSchemaHookCompletedNotification)
    case commandExecOutputDelta(CodexSchemaCommandExecOutputDeltaNotification)
    case processOutputDelta(CodexSchemaProcessOutputDeltaNotification)
    case processExited(CodexSchemaProcessExitedNotification)
    case fuzzyFileSearchSessionUpdated(CodexSchemaFuzzyFileSearchSessionUpdatedNotification)
    case fuzzyFileSearchSessionCompleted(CodexSchemaFuzzyFileSearchSessionCompletedNotification)
    case threadRealtimeStarted(CodexSchemaThreadRealtimeStartedNotification)
    case threadRealtimeItemAdded(CodexSchemaThreadRealtimeItemAddedNotification)
    case threadRealtimeTranscriptDelta(CodexSchemaThreadRealtimeTranscriptDeltaNotification)
    case threadRealtimeTranscriptDone(CodexSchemaThreadRealtimeTranscriptDoneNotification)
    case threadRealtimeOutputAudioDelta(CodexSchemaThreadRealtimeOutputAudioDeltaNotification)
    case threadRealtimeSDP(CodexSchemaThreadRealtimeSdpNotification)
    case threadRealtimeError(CodexSchemaThreadRealtimeErrorNotification)
    case threadRealtimeClosed(CodexSchemaThreadRealtimeClosedNotification)
    case mcpServerStartupStatusUpdated(CodexSchemaMCPServerStatusUpdatedNotification)
    case mcpServerOAuthLoginCompleted(CodexSchemaMCPServerOAuthLoginCompletedNotification)
    case appListUpdated(CodexSchemaAppListUpdatedNotification)
    case remoteControlStatusChanged(CodexSchemaRemoteControlStatusChangedNotification)
    case externalAgentConfigImportProgress(CodexSchemaExternalAgentConfigImportProgressNotification)
    case externalAgentConfigImportCompleted(CodexSchemaExternalAgentConfigImportCompletedNotification)
    case fileSystemChanged(CodexSchemaFSChangedNotification)
    case windowsSandboxSetupCompleted(CodexSchemaWindowsSandboxSetupCompletedNotification)
    case accountLoginCompleted(CodexSchemaAccountLoginCompletedNotification)

    public var method: CodexAppServerNotificationMethod {
        switch self {
        case .skillsChanged:
            .skillsChanged
        case .hookStarted:
            .hookStarted
        case .hookCompleted:
            .hookCompleted
        case .commandExecOutputDelta:
            .commandExecOutputDelta
        case .processOutputDelta:
            .processOutputDelta
        case .processExited:
            .processExited
        case .fuzzyFileSearchSessionUpdated:
            .fuzzyFileSearchSessionUpdated
        case .fuzzyFileSearchSessionCompleted:
            .fuzzyFileSearchSessionCompleted
        case .threadRealtimeStarted:
            .threadRealtimeStarted
        case .threadRealtimeItemAdded:
            .threadRealtimeItemAdded
        case .threadRealtimeTranscriptDelta:
            .threadRealtimeTranscriptDelta
        case .threadRealtimeTranscriptDone:
            .threadRealtimeTranscriptDone
        case .threadRealtimeOutputAudioDelta:
            .threadRealtimeOutputAudioDelta
        case .threadRealtimeSDP:
            .threadRealtimeSdp
        case .threadRealtimeError:
            .threadRealtimeError
        case .threadRealtimeClosed:
            .threadRealtimeClosed
        case .mcpServerStartupStatusUpdated:
            .mcpServerStartupStatusUpdated
        case .mcpServerOAuthLoginCompleted:
            .mcpServerOAuthLoginCompleted
        case .appListUpdated:
            .appListUpdated
        case .remoteControlStatusChanged:
            .remoteControlStatusChanged
        case .externalAgentConfigImportProgress:
            .externalAgentConfigImportProgress
        case .externalAgentConfigImportCompleted:
            .externalAgentConfigImportCompleted
        case .fileSystemChanged:
            .fsChanged
        case .windowsSandboxSetupCompleted:
            .windowsSandboxSetupCompleted
        case .accountLoginCompleted:
            .accountLoginCompleted
        }
    }

    /// Whether this notification is the protocol terminal for its correlation.
    /// Request responses may also terminate a channel through `finish(key:)`.
    public var isTerminal: Bool {
        switch self {
        case .hookCompleted,
             .processExited,
             .fuzzyFileSearchSessionCompleted,
             .threadRealtimeClosed,
             .mcpServerOAuthLoginCompleted,
             .externalAgentConfigImportCompleted,
             .windowsSandboxSetupCompleted,
             .accountLoginCompleted:
            true

        case .mcpServerStartupStatusUpdated(let value):
            switch value.status {
            case .starting:
                false
            case .ready, .failed, .cancelled:
                true
            case .unrecognized:
                false
            }

        case .skillsChanged,
             .hookStarted,
             .commandExecOutputDelta,
             .processOutputDelta,
             .fuzzyFileSearchSessionUpdated,
             .threadRealtimeStarted,
             .threadRealtimeItemAdded,
             .threadRealtimeTranscriptDelta,
             .threadRealtimeTranscriptDone,
             .threadRealtimeOutputAudioDelta,
             .threadRealtimeSDP,
             .threadRealtimeError,
             .appListUpdated,
             .remoteControlStatusChanged,
             .externalAgentConfigImportProgress,
             .fileSystemChanged:
            false
        }
    }

    fileprivate var correlation: CodexOperationCorrelation {
        switch self {
        case .skillsChanged:
            .skills
        case .hookStarted(let value):
            .hook(threadID: value.threadID, runID: value.run.id)
        case .hookCompleted(let value):
            .hook(threadID: value.threadID, runID: value.run.id)
        case .commandExecOutputDelta(let value):
            .commandExec(processID: value.processID)
        case .processOutputDelta(let value):
            .process(handle: value.processHandle)
        case .processExited(let value):
            .process(handle: value.processHandle)
        case .fuzzyFileSearchSessionUpdated(let value):
            .fuzzyFileSearch(sessionID: value.sessionID)
        case .fuzzyFileSearchSessionCompleted(let value):
            .fuzzyFileSearch(sessionID: value.sessionID)
        case .threadRealtimeStarted(let value):
            .realtime(threadID: value.threadID)
        case .threadRealtimeItemAdded(let value):
            .realtime(threadID: value.threadID)
        case .threadRealtimeTranscriptDelta(let value):
            .realtime(threadID: value.threadID)
        case .threadRealtimeTranscriptDone(let value):
            .realtime(threadID: value.threadID)
        case .threadRealtimeOutputAudioDelta(let value):
            .realtime(threadID: value.threadID)
        case .threadRealtimeSDP(let value):
            .realtime(threadID: value.threadID)
        case .threadRealtimeError(let value):
            .realtime(threadID: value.threadID)
        case .threadRealtimeClosed(let value):
            .realtime(threadID: value.threadID)
        case .mcpServerStartupStatusUpdated(let value):
            .mcpServerStartup(name: value.name, threadID: value.threadID)
        case .mcpServerOAuthLoginCompleted(let value):
            .mcpServerOAuth(name: value.name, threadID: value.threadID)
        case .appListUpdated:
            .applications
        case .remoteControlStatusChanged(let value):
            .remoteControl(installationID: value.installationID)
        case .externalAgentConfigImportProgress(let value):
            .externalAgentConfigImport(importID: value.importID)
        case .externalAgentConfigImportCompleted(let value):
            .externalAgentConfigImport(importID: value.importID)
        case .fileSystemChanged(let value):
            .fileSystemWatch(watchID: value.watchID)
        case .windowsSandboxSetupCompleted(let value):
            .windowsSandbox(mode: value.mode.rawValue)
        case .accountLoginCompleted(let value):
            .accountLogin(loginID: value.loginID)
        }
    }
}

/// One decoded auxiliary-operation fact at its exact ordered-wire position.
public struct CodexOperationEvent: Sendable, Equatable {
    public let cursor: CodexWireCursor
    public let key: CodexOperationKey
    public let payload: CodexOperationEventPayload

    public var method: CodexAppServerNotificationMethod {
        payload.method
    }

    public var isTerminal: Bool {
        payload.isTerminal
    }

    fileprivate init(
        cursor: CodexWireCursor,
        payload: CodexOperationEventPayload
    ) {
        self.cursor = cursor
        self.key = CodexOperationKey(
            connectionEpoch: cursor.connectionEpoch,
            correlation: payload.correlation
        )
        self.payload = payload
    }
}

public enum CodexOperationRegistryError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedNotification(String)
    case malformedNotification(method: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedNotification(let method):
            "Notification \(method) is not an auxiliary operation."
        case .malformedNotification(let method, let message):
            "Malformed auxiliary notification \(method): \(message)"
        }
    }
}

public enum CodexOperationChannelError: Error, Sendable, Equatable, LocalizedError {
    case disconnected(connectionEpoch: UInt64)
    case bufferOverflow(
        key: CodexOperationKey,
        maximumBufferedEventCount: Int
    )

    public var errorDescription: String? {
        switch self {
        case .disconnected(let connectionEpoch):
            "Operation channel disconnected with connection epoch \(connectionEpoch)."
        case .bufferOverflow(let key, let maximumBufferedEventCount):
            "Operation channel \(key) exceeded its \(maximumBufferedEventCount)-event buffer."
        }
    }
}

public struct CodexOperationChannelToken: RawRepresentable, Sendable, Hashable, Comparable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Determines when the registry finishes a channel after publishing an event.
public enum CodexOperationChannelLifetime: Sendable, Hashable {
    /// Finish after the first matching event. This is the one-shot waiter mode.
    case firstEvent
    /// Finish after a typed terminal event, or an explicit response-side finish.
    case untilTerminal
    /// Remain active until explicit cancellation, finish, or disconnect.
    case explicit
}

/// A per-key, ordered channel registered before an initiating request is written.
///
/// Accepted events are never silently coalesced or dropped. A stalled consumer
/// that exhausts its configured buffer receives an explicit terminal overflow.
public struct CodexOperationChannel: Sendable {
    public let token: CodexOperationChannelToken
    public let key: CodexOperationKey
    public let events: AsyncThrowingStream<CodexOperationEvent, Error>

    fileprivate init(
        token: CodexOperationChannelToken,
        key: CodexOperationKey,
        events: AsyncThrowingStream<CodexOperationEvent, Error>
    ) {
        self.token = token
        self.key = key
        self.events = events
    }
}

public enum CodexOperationDiagnosticKind: Sendable, Hashable {
    case warning
    case unknownMethod
    case unmatchedOperation
    case malformedOperation
    case bufferOverflow
}

public enum CodexDiagnosticSeverity: String, Codable, Sendable, Hashable {
    case info
    case warning
    case error
}

/// Bounded metadata for an operation frame that was not published to a channel.
/// Raw notification parameters are deliberately never retained here.
public struct CodexOperationDiagnostic: Sendable, Equatable {
    public let cursor: CodexWireCursor
    public let kind: CodexOperationDiagnosticKind
    public let severity: CodexDiagnosticSeverity
    public let method: String
    public let threadID: ThreadID?
    public let keyDescription: String?
    public let detail: String?
    public let content: CodexProtocolDiagnosticContent?

    /// Stable identity for this process-local diagnostic fact.
    public var id: CodexWireCursor { cursor }

    public init(
        cursor: CodexWireCursor,
        kind: CodexOperationDiagnosticKind,
        severity: CodexDiagnosticSeverity? = nil,
        method: String,
        threadID: ThreadID? = nil,
        keyDescription: String? = nil,
        detail: String? = nil,
        content: CodexProtocolDiagnosticContent? = nil
    ) {
        self.cursor = cursor
        self.kind = kind
        self.severity = severity ?? kind.defaultSeverity
        self.method = method
        self.threadID = threadID
        self.keyDescription = keyDescription
        self.detail = detail
        self.content = content
    }
}

private extension CodexOperationDiagnosticKind {
    var defaultSeverity: CodexDiagnosticSeverity {
        switch self {
        case .warning:
            .warning
        case .malformedOperation, .bufferOverflow:
            .error
        case .unknownMethod, .unmatchedOperation:
            .info
        }
    }
}

public struct CodexOperationRegistryLimits: Sendable, Hashable {
    public let maximumDiagnosticEntries: Int
    public let maximumDiagnosticTextUTF8Bytes: Int
    public let maximumDiagnosticSamplePaths: Int
    public let defaultMaximumBufferedEventsPerChannel: Int

    public init(
        maximumDiagnosticEntries: Int = 128,
        maximumDiagnosticTextUTF8Bytes: Int = 256,
        maximumDiagnosticSamplePaths: Int = 8,
        defaultMaximumBufferedEventsPerChannel: Int = 512
    ) {
        precondition(
            maximumDiagnosticEntries > 0,
            "Operation diagnostic entry limit must be positive"
        )
        precondition(
            maximumDiagnosticTextUTF8Bytes > 0,
            "Operation diagnostic text limit must be positive"
        )
        precondition(
            maximumDiagnosticSamplePaths > 0,
            "Operation diagnostic sample-path limit must be positive"
        )
        precondition(
            defaultMaximumBufferedEventsPerChannel > 0,
            "Operation channel event limit must be positive"
        )
        self.maximumDiagnosticEntries = maximumDiagnosticEntries
        self.maximumDiagnosticTextUTF8Bytes = maximumDiagnosticTextUTF8Bytes
        self.maximumDiagnosticSamplePaths = maximumDiagnosticSamplePaths
        self.defaultMaximumBufferedEventsPerChannel =
            defaultMaximumBufferedEventsPerChannel
    }
}

public struct CodexOperationDiagnosticsSnapshot: Sendable, Equatable {
    public let entries: [CodexOperationDiagnostic]
    public let totalRecordedCount: UInt64
    public let evictedCount: UInt64

    public init(
        entries: [CodexOperationDiagnostic],
        totalRecordedCount: UInt64,
        evictedCount: UInt64
    ) {
        self.entries = entries
        self.totalRecordedCount = totalRecordedCount
        self.evictedCount = evictedCount
    }

    public static let empty = Self(
        entries: [],
        totalRecordedCount: 0,
        evictedCount: 0
    )
}

public struct CodexOperationIngestResult: Sendable, Equatable {
    public let event: CodexOperationEvent
    public let matchedChannelCount: Int
    public let deliveredChannelCount: Int
    public let completedChannelCount: Int
    public let overflowedChannelCount: Int

    public var wasUnmatched: Bool {
        matchedChannelCount == 0
    }

    public init(
        event: CodexOperationEvent,
        matchedChannelCount: Int,
        deliveredChannelCount: Int,
        completedChannelCount: Int,
        overflowedChannelCount: Int
    ) {
        self.event = event
        self.matchedChannelCount = matchedChannelCount
        self.deliveredChannelCount = deliveredChannelCount
        self.completedChannelCount = completedChannelCount
        self.overflowedChannelCount = overflowedChannelCount
    }
}

/// Synchronous auxiliary-operation state owned by the sole `CodexSession` actor.
///
/// The registry performs no I/O and creates no executor. Registering a channel
/// and queuing its initiating request can therefore occur in one actor turn,
/// closing the response/notification race.
public struct CodexOperationRegistry: ~Copyable {
    private struct ChannelEntry: Sendable {
        let key: CodexOperationKey
        let lifetime: CodexOperationChannelLifetime
        let maximumBufferedEventCount: Int
        let continuation: AsyncThrowingStream<CodexOperationEvent, Error>.Continuation
    }

    public let limits: CodexOperationRegistryLimits

    private var nextTokenRawValue: UInt64 = 1
    private var channels: [CodexOperationChannelToken: ChannelEntry] = [:]
    private var tokensByKey: [CodexOperationKey: [CodexOperationChannelToken]] = [:]

    private var diagnosticRing: [CodexOperationDiagnostic?]
    private var diagnosticHead = 0
    private var diagnosticCount = 0
    private var totalDiagnosticCount: UInt64 = 0
    private var evictedDiagnosticCount: UInt64 = 0

    public init(limits: CodexOperationRegistryLimits = .init()) {
        self.limits = limits
        self.diagnosticRing = Array(
            repeating: nil,
            count: limits.maximumDiagnosticEntries
        )
    }

    public var activeChannelCount: Int {
        channels.count
    }

    public func activeChannelCount(for key: CodexOperationKey) -> Int {
        tokensByKey[key]?.count ?? 0
    }

    /// Whether this generated notification participates in an auxiliary
    /// operation channel. Some methods (notably hooks) also mutate canonical
    /// state, so callers must not infer this solely from adapter disposition.
    public static func supports(_ method: CodexAppServerNotificationMethod) -> Bool {
        switch method {
        case .skillsChanged,
             .hookStarted, .hookCompleted,
             .commandExecOutputDelta,
             .processOutputDelta, .processExited,
             .fuzzyFileSearchSessionUpdated, .fuzzyFileSearchSessionCompleted,
             .threadRealtimeStarted, .threadRealtimeItemAdded,
             .threadRealtimeTranscriptDelta, .threadRealtimeTranscriptDone,
             .threadRealtimeOutputAudioDelta, .threadRealtimeSdp,
             .threadRealtimeError, .threadRealtimeClosed,
             .mcpServerStartupStatusUpdated, .mcpServerOAuthLoginCompleted,
             .appListUpdated, .remoteControlStatusChanged,
             .externalAgentConfigImportProgress, .externalAgentConfigImportCompleted,
             .fsChanged, .windowsSandboxSetupCompleted, .accountLoginCompleted:
            true
        default:
            false
        }
    }

    /// Registers a lossless, exactly-keyed channel.
    ///
    /// `onTermination` must enqueue `cancel(_:)` back onto the owning actor when
    /// callers can abandon iteration before a protocol terminal is observed.
    public mutating func register(
        key: CodexOperationKey,
        lifetime: CodexOperationChannelLifetime = .untilTerminal,
        maximumBufferedEventCount: Int? = nil,
        onTermination: (@Sendable (CodexOperationChannelToken) -> Void)? = nil
    ) -> CodexOperationChannel {
        precondition(
            nextTokenRawValue < UInt64.max,
            "Operation channel identity space exhausted"
        )
        let token = CodexOperationChannelToken(rawValue: nextTokenRawValue)
        nextTokenRawValue += 1

        let bufferLimit = maximumBufferedEventCount
            ?? limits.defaultMaximumBufferedEventsPerChannel
        precondition(bufferLimit > 0, "Operation channel event limit must be positive")

        let pair = AsyncThrowingStream<CodexOperationEvent, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(bufferLimit)
        )
        pair.continuation.onTermination = { @Sendable _ in
            onTermination?(token)
        }

        channels[token] = ChannelEntry(
            key: key,
            lifetime: lifetime,
            maximumBufferedEventCount: bufferLimit,
            continuation: pair.continuation
        )
        tokensByKey[key, default: []].append(token)
        return CodexOperationChannel(
            token: token,
            key: key,
            events: pair.stream
        )
    }

    /// Convenience for a one-shot, lossless next-event waiter.
    public mutating func registerWaiter(
        key: CodexOperationKey,
        maximumBufferedEventCount: Int? = nil,
        onTermination: (@Sendable (CodexOperationChannelToken) -> Void)? = nil
    ) -> CodexOperationChannel {
        register(
            key: key,
            lifetime: .firstEvent,
            maximumBufferedEventCount: maximumBufferedEventCount,
            onTermination: onTermination
        )
    }

    /// Decodes and publishes one adapter-classified operation notification.
    /// This method must be invoked exactly once at the frame's wire cursor.
    @discardableResult
    public mutating func ingest(
        method: CodexAppServerNotificationMethod,
        params: [String: CodexJSONValue],
        cursor: CodexWireCursor
    ) throws -> CodexOperationIngestResult {
        let event: CodexOperationEvent
        do {
            event = try Self.decode(method: method, params: params, cursor: cursor)
        } catch {
            let registryError: CodexOperationRegistryError
            if let error = error as? CodexOperationRegistryError {
                registryError = error
            } else {
                registryError = .malformedNotification(
                    method: method.rawValue,
                    message: String(describing: error)
                )
            }
            recordDiagnostic(
                kind: .malformedOperation,
                method: method.rawValue,
                cursor: cursor,
                detail: registryError.localizedDescription
            )
            throw registryError
        }

        let recipientTokens = tokensByKey[event.key] ?? []
        var matchedCount = 0
        var deliveredCount = 0
        var completedCount = 0
        var overflowedCount = 0

        for token in recipientTokens {
            guard let entry = channels[token] else { continue }
            matchedCount += 1
            let shouldFinishAfterDelivery = switch entry.lifetime {
            case .firstEvent:
                true
            case .untilTerminal:
                event.isTerminal
            case .explicit:
                false
            }
            if shouldFinishAfterDelivery {
                // Publish terminal state from the registry before resuming the
                // consumer through the continuation.
                _ = removeChannel(token)
            }

            switch entry.continuation.yield(event) {
            case .enqueued:
                deliveredCount += 1
                if shouldFinishAfterDelivery {
                    entry.continuation.finish()
                    completedCount += 1
                }

            case .terminated:
                if !shouldFinishAfterDelivery {
                    _ = removeChannel(token)
                }

            case .dropped:
                let failed = shouldFinishAfterDelivery ? entry : removeChannel(token)
                if let failed {
                    failed.continuation.finish(throwing: CodexOperationChannelError.bufferOverflow(
                        key: event.key,
                        maximumBufferedEventCount: failed.maximumBufferedEventCount
                    ))
                    overflowedCount += 1
                    recordDiagnostic(
                        kind: .bufferOverflow,
                        method: method.rawValue,
                        cursor: cursor,
                        keyDescription: event.key.diagnosticDescription,
                        detail: "maximumBufferedEventCount=\(failed.maximumBufferedEventCount)"
                    )
                }
            @unknown default:
                let failed = shouldFinishAfterDelivery ? entry : removeChannel(token)
                if let failed {
                    failed.continuation.finish(throwing: CodexOperationChannelError.bufferOverflow(
                        key: event.key,
                        maximumBufferedEventCount: failed.maximumBufferedEventCount
                    ))
                    overflowedCount += 1
                    recordDiagnostic(
                        kind: .bufferOverflow,
                        method: method.rawValue,
                        cursor: cursor,
                        keyDescription: event.key.diagnosticDescription,
                        detail: "unknown yield result"
                    )
                }
            }
        }

        if matchedCount == 0 {
            recordDiagnostic(
                kind: .unmatchedOperation,
                method: method.rawValue,
                cursor: cursor,
                keyDescription: event.key.diagnosticDescription
            )
        }

        return CodexOperationIngestResult(
            event: event,
            matchedChannelCount: matchedCount,
            deliveredChannelCount: deliveredCount,
            completedChannelCount: completedCount,
            overflowedChannelCount: overflowedCount
        )
    }

    /// Finishes all channels for a response-driven terminal operation.
    @discardableResult
    public mutating func finish(key: CodexOperationKey) -> Int {
        let tokens = tokensByKey[key] ?? []
        var finishedCount = 0
        for token in tokens {
            guard let entry = removeChannel(token) else { continue }
            entry.continuation.finish()
            finishedCount += 1
        }
        return finishedCount
    }

    /// Cancels one local consumer. Cancellation is not a protocol terminal.
    @discardableResult
    public mutating func cancel(_ token: CodexOperationChannelToken) -> Bool {
        guard let entry = removeChannel(token) else { return false }
        entry.continuation.finish(throwing: CancellationError())
        return true
    }

    /// Fails only channels from the disconnected physical connection.
    @discardableResult
    public mutating func disconnect(connectionEpoch: UInt64) -> Int {
        let tokens = channels.compactMap { token, entry in
            entry.key.connectionEpoch == connectionEpoch ? token : nil
        }.sorted()
        var disconnectedCount = 0
        for token in tokens {
            guard let entry = removeChannel(token) else { continue }
            entry.continuation.finish(
                throwing: CodexOperationChannelError.disconnected(
                    connectionEpoch: connectionEpoch
                )
            )
            disconnectedCount += 1
        }
        return disconnectedCount
    }

    /// Records bounded warning/unknown metadata without retaining raw params.
    public mutating func recordDiagnostic(
        kind: CodexOperationDiagnosticKind,
        method: String,
        cursor: CodexWireCursor,
        keyDescription: String? = nil,
        detail: String? = nil
    ) {
        let boundedKeyDescription = keyDescription.map { value in
            truncatedDiagnosticText(value)
        }
        let boundedDetail = detail.map { value in
            truncatedDiagnosticText(value)
        }
        appendDiagnostic(CodexOperationDiagnostic(
            cursor: cursor,
            kind: kind,
            method: truncatedDiagnosticText(method),
            keyDescription: boundedKeyDescription,
            detail: boundedDetail
        ))
    }

    public func diagnostics() -> CodexOperationDiagnosticsSnapshot {
        var entries: [CodexOperationDiagnostic] = []
        entries.reserveCapacity(diagnosticCount)
        for offset in 0..<diagnosticCount {
            let index = (diagnosticHead + offset) % diagnosticRing.count
            if let entry = diagnosticRing[index] {
                entries.append(entry)
            }
        }
        return CodexOperationDiagnosticsSnapshot(
            entries: entries,
            totalRecordedCount: totalDiagnosticCount,
            evictedCount: evictedDiagnosticCount
        )
    }
}

private extension CodexOperationRegistry {
    static func decode(
        method: CodexAppServerNotificationMethod,
        params: [String: CodexJSONValue],
        cursor: CodexWireCursor
    ) throws -> CodexOperationEvent {
        let payload: CodexOperationEventPayload
        switch method {
        case .skillsChanged:
            payload = .skillsChanged(try params.decode(CodexSchemaSkillsChangedNotification.self))
        case .hookStarted:
            payload = .hookStarted(try params.decode(CodexSchemaHookStartedNotification.self))
        case .hookCompleted:
            payload = .hookCompleted(try params.decode(CodexSchemaHookCompletedNotification.self))
        case .commandExecOutputDelta:
            payload = .commandExecOutputDelta(
                try params.decode(CodexSchemaCommandExecOutputDeltaNotification.self)
            )
        case .processOutputDelta:
            payload = .processOutputDelta(
                try params.decode(CodexSchemaProcessOutputDeltaNotification.self)
            )
        case .processExited:
            payload = .processExited(try params.decode(CodexSchemaProcessExitedNotification.self))
        case .fuzzyFileSearchSessionUpdated:
            payload = .fuzzyFileSearchSessionUpdated(
                try params.decode(CodexSchemaFuzzyFileSearchSessionUpdatedNotification.self)
            )
        case .fuzzyFileSearchSessionCompleted:
            payload = .fuzzyFileSearchSessionCompleted(
                try params.decode(CodexSchemaFuzzyFileSearchSessionCompletedNotification.self)
            )
        case .threadRealtimeStarted:
            payload = .threadRealtimeStarted(
                try params.decode(CodexSchemaThreadRealtimeStartedNotification.self)
            )
        case .threadRealtimeItemAdded:
            payload = .threadRealtimeItemAdded(
                try params.decode(CodexSchemaThreadRealtimeItemAddedNotification.self)
            )
        case .threadRealtimeTranscriptDelta:
            payload = .threadRealtimeTranscriptDelta(
                try params.decode(CodexSchemaThreadRealtimeTranscriptDeltaNotification.self)
            )
        case .threadRealtimeTranscriptDone:
            payload = .threadRealtimeTranscriptDone(
                try params.decode(CodexSchemaThreadRealtimeTranscriptDoneNotification.self)
            )
        case .threadRealtimeOutputAudioDelta:
            payload = .threadRealtimeOutputAudioDelta(
                try params.decode(CodexSchemaThreadRealtimeOutputAudioDeltaNotification.self)
            )
        case .threadRealtimeSdp:
            payload = .threadRealtimeSDP(
                try params.decode(CodexSchemaThreadRealtimeSdpNotification.self)
            )
        case .threadRealtimeError:
            payload = .threadRealtimeError(
                try params.decode(CodexSchemaThreadRealtimeErrorNotification.self)
            )
        case .threadRealtimeClosed:
            payload = .threadRealtimeClosed(
                try params.decode(CodexSchemaThreadRealtimeClosedNotification.self)
            )
        case .mcpServerStartupStatusUpdated:
            payload = .mcpServerStartupStatusUpdated(
                try params.decode(CodexSchemaMCPServerStatusUpdatedNotification.self)
            )
        case .mcpServerOAuthLoginCompleted:
            payload = .mcpServerOAuthLoginCompleted(
                try params.decode(CodexSchemaMCPServerOAuthLoginCompletedNotification.self)
            )
        case .appListUpdated:
            payload = .appListUpdated(try params.decode(CodexSchemaAppListUpdatedNotification.self))
        case .remoteControlStatusChanged:
            payload = .remoteControlStatusChanged(
                try params.decode(CodexSchemaRemoteControlStatusChangedNotification.self)
            )
        case .externalAgentConfigImportProgress:
            payload = .externalAgentConfigImportProgress(
                try params.decode(CodexSchemaExternalAgentConfigImportProgressNotification.self)
            )
        case .externalAgentConfigImportCompleted:
            payload = .externalAgentConfigImportCompleted(
                try params.decode(CodexSchemaExternalAgentConfigImportCompletedNotification.self)
            )
        case .fsChanged:
            payload = .fileSystemChanged(try params.decode(CodexSchemaFSChangedNotification.self))
        case .windowsSandboxSetupCompleted:
            payload = .windowsSandboxSetupCompleted(
                try params.decode(CodexSchemaWindowsSandboxSetupCompletedNotification.self)
            )
        case .accountLoginCompleted:
            payload = .accountLoginCompleted(
                try params.decode(CodexSchemaAccountLoginCompletedNotification.self)
            )

        default:
            throw CodexOperationRegistryError.unsupportedNotification(method.rawValue)
        }
        return CodexOperationEvent(cursor: cursor, payload: payload)
    }

    private mutating func removeChannel(
        _ token: CodexOperationChannelToken
    ) -> ChannelEntry? {
        guard let entry = channels.removeValue(forKey: token) else { return nil }
        if var tokens = tokensByKey[entry.key] {
            tokens.removeAll { $0 == token }
            if tokens.isEmpty {
                tokensByKey.removeValue(forKey: entry.key)
            } else {
                tokensByKey[entry.key] = tokens
            }
        }
        return entry
    }

    mutating func appendDiagnostic(_ diagnostic: CodexOperationDiagnostic) {
        if totalDiagnosticCount < UInt64.max {
            totalDiagnosticCount += 1
        }

        if diagnosticCount < diagnosticRing.count {
            let index = (diagnosticHead + diagnosticCount) % diagnosticRing.count
            diagnosticRing[index] = diagnostic
            diagnosticCount += 1
        } else {
            diagnosticRing[diagnosticHead] = diagnostic
            diagnosticHead = (diagnosticHead + 1) % diagnosticRing.count
            if evictedDiagnosticCount < UInt64.max {
                evictedDiagnosticCount += 1
            }
        }
    }

    func truncatedDiagnosticText(_ value: String) -> String {
        let limit = limits.maximumDiagnosticTextUTF8Bytes
        guard value.utf8.count > limit else { return value }

        var result = String.UnicodeScalarView()
        var byteCount = 0
        for scalar in value.unicodeScalars {
            let scalarByteCount = String(scalar).utf8.count
            guard byteCount + scalarByteCount <= limit else { break }
            result.append(scalar)
            byteCount += scalarByteCount
        }
        return String(result)
    }
}

private extension CodexOperationKey {
    var diagnosticDescription: String {
        "epoch=\(connectionEpoch),\(correlation.diagnosticDescription)"
    }
}

private extension CodexOperationCorrelation {
    var diagnosticDescription: String {
        switch self {
        case .skills:
            "skills"
        case .hook(let threadID, let runID):
            "hook(thread=\(threadID),run=\(runID))"
        case .commandExec(let processID):
            "commandExec(process=\(processID))"
        case .process(let handle):
            "process(handle=\(handle))"
        case .fuzzyFileSearch(let sessionID):
            "fuzzyFileSearch(session=\(sessionID))"
        case .realtime(let threadID):
            "realtime(thread=\(threadID))"
        case .mcpServerStartup(let name, let threadID):
            "mcpStartup(name=\(name),thread=\(threadID ?? "global"))"
        case .mcpServerOAuth(let name, let threadID):
            "mcpOAuth(name=\(name),thread=\(threadID ?? "global"))"
        case .applications:
            "applications"
        case .remoteControl(let installationID):
            "remoteControl(installation=\(installationID))"
        case .externalAgentConfigImport(let importID):
            "externalAgentConfig(import=\(importID))"
        case .fileSystemWatch(let watchID):
            "fileSystem(watch=\(watchID))"
        case .windowsSandbox(let mode):
            "windowsSandbox(mode=\(mode))"
        case .accountLogin(let loginID):
            "accountLogin(id=\(loginID ?? "missing"))"
        }
    }
}
