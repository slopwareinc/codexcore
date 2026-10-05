import Foundation
import Observation
import CodexCore

struct CodexAppRuntimeNoticeSelection: Hashable, Sendable {
    var threadID: String?
    var turnID: String?

    var stateScope: StateObservationScope {
        let fields: StateFieldMask = [.turnMetadata, .turnStatus, .moderation, .extensions]
        guard let threadID else { return .global(fields: fields) }
        if let turnID { return .init(entities: .turn(.init(threadID: .init(threadID), turnID: .init(turnID))), fields: fields) }
        return .init(entities: .thread(.init(threadID)), fields: fields)
    }
}

struct CodexAppRuntimeNoticeSnapshot: Sendable {
    let connectionEpoch: UInt64
    let canonical: CanonicalStateSnapshot
    let diagnostics: [CodexProtocolDiagnosticEntry]
}

protocol CodexAppRuntimeNoticeProviding: Sendable {
    func observe(_ selection: CodexAppRuntimeNoticeSelection) async throws -> AsyncThrowingStream<CodexAppRuntimeNoticeSnapshot, Error>
}

/// Existing typed state invalidations provide a coalesced observer; this adds
/// no polling or second raw-protocol listener. One reader publishes snapshots.
struct CodexAppRuntimeNoticeProvider: CodexAppRuntimeNoticeProviding {
    let codex: Codex

    func observe(_ selection: CodexAppRuntimeNoticeSelection) async throws -> AsyncThrowingStream<CodexAppRuntimeNoticeSnapshot, Error> {
        let session = codex.session
        let scope = selection.stateScope
        let state = await session.observeSessionState(scope: scope)
        let diagnostics = await session.observeSessionState(scope: .global(fields: .diagnostics))
        guard case .ready(let epoch) = state.seed.lifecycle else {
            await session.cancelObservation(state.id)
            await session.cancelObservation(diagnostics.id)
            throw CodexAppFeatureError.disconnected
        }
        let refresh = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let result = AsyncThrowingStream<CodexAppRuntimeNoticeSnapshot, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let producers = [state.signals, diagnostics.signals].map { signals in
            Task {
                for await _ in signals {
                    guard !Task.isCancelled else { return }
                    refresh.continuation.yield(())
                }
            }
        }
        let reader = Task {
            do {
                refresh.continuation.yield(())
                for await _ in refresh.stream {
                    try Task.checkCancellation()
                    let snapshot = await session.sessionStateSnapshot(scope: scope)
                    guard case .ready(let current) = snapshot.lifecycle, current == epoch else { break }
                    let entries = await session.protocolDiagnostics().entries.filter { $0.cursor.connectionEpoch == epoch }
                    result.continuation.yield(.init(connectionEpoch: epoch, canonical: snapshot.canonical, diagnostics: entries))
                }
                result.continuation.finish()
            } catch { result.continuation.finish(throwing: error) }
        }
        result.continuation.onTermination = { _ in
            reader.cancel()
            producers.forEach { $0.cancel() }
            refresh.continuation.finish()
            Task {
                await session.cancelObservation(state.id)
                await session.cancelObservation(diagnostics.id)
            }
        }
        return result.stream
    }
}

struct CodexAppRuntimeNotice: Identifiable, Equatable {
    enum Kind: String { case verification, authentication, buffering, moderation, rerouting, guardian, diagnostic }
    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let severity: CodexDiagnosticSeverity
}

@Observable @MainActor
final class CodexAppRuntimeNoticeFeatures {
    private(set) var notices: [CodexAppRuntimeNotice] = []
    private(set) var errorMessage: String?
    @ObservationIgnored private var provider: (any CodexAppRuntimeNoticeProviding)?
    @ObservationIgnored private var selection = CodexAppRuntimeNoticeSelection()
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var connectionEpoch: UInt64?
    @ObservationIgnored private var observationTask: Task<Void, Never>?

    func bind(_ provider: (any CodexAppRuntimeNoticeProviding)?) async {
        self.provider = provider
        connectionEpoch = nil
        await restart()
    }

    func select(threadID: String?, turnID: String?) async {
        let value = CodexAppRuntimeNoticeSelection(threadID: threadID, turnID: turnID)
        guard value != selection else { return }
        selection = value
        await restart()
    }

    private func restart() async {
        generation &+= 1
        let expected = generation
        let selected = selection
        observationTask?.cancel()
        observationTask = nil
        notices = []
        errorMessage = nil
        guard let provider else { return }
        do {
            let stream = try await provider.observe(selected)
            guard expected == generation else { return }
            observationTask = Task { [weak self] in
                do {
                    for try await value in stream {
                        guard let self, self.generation == expected, !Task.isCancelled else { return }
                        guard self.connectionEpoch == nil || self.connectionEpoch == value.connectionEpoch else { continue }
                        self.connectionEpoch = value.connectionEpoch
                        self.notices = Self.present(value, selection: selected)
                    }
                } catch {
                    guard let self, self.generation == expected, !Task.isCancelled else { return }
                    self.errorMessage = "Runtime notices stopped updating. Reconnect to restore them."
                }
            }
        } catch {
            if generation == expected { errorMessage = "Runtime notices are unavailable until Codex is connected." }
        }
    }

    static func present(_ snapshot: CodexAppRuntimeNoticeSnapshot, selection: CodexAppRuntimeNoticeSelection) -> [CodexAppRuntimeNotice] {
        var result: [CodexAppRuntimeNotice] = []
        if let threadID = selection.threadID {
            let id = ThreadID(threadID)
            let turnID = selection.turnID.map { TurnID($0) } ?? snapshot.canonical.threads[id]?.turnOrder.last
            if let turnID, let turn = snapshot.canonical.turns[.init(threadID: id, turnID: turnID)] {
                result += turnNotices(turn)
            }
        }
        let diagnostics = snapshot.diagnostics.filter {
            $0.cursor.connectionEpoch == snapshot.connectionEpoch && ($0.threadID == nil || $0.threadID?.rawValue == selection.threadID)
        }.suffix(6)
        for entry in diagnostics {
            let text: (String, String)?
            switch entry.content {
            case .warning(let message): text = ("Runtime warning", bounded(message))
            case .guardianWarning(let message): text = ("Guardian warning", bounded(message))
            case .deprecationNotice(let summary, let details): text = ("Deprecated feature", diagnosticText(summary, details))
            case .configWarning(let summary, let details, let path):
                text = ("Configuration warning", diagnosticText(summary, details, location: path))
            case .windowsWorldWritableWarning: text = nil
            case nil:
                text = entry.severity == .error ? ("Runtime protocol issue", "Some runtime events could not be applied. Reconnect to restore live updates.") : nil
            }
            guard let text else { continue }
            result.append(.init(id: "diagnostic:\(entry.cursor.connectionEpoch):\(entry.cursor.ordinal)", kind: .diagnostic,
                                title: text.0, detail: text.1, severity: entry.severity))
        }
        return result
    }

    private static func turnNotices(_ turn: CanonicalTurn) -> [CodexAppRuntimeNotice] {
        var result: [CodexAppRuntimeNotice] = []
        let prefix = "turn:\(turn.key.threadID.rawValue):\(turn.key.turnID.rawValue)"
        func add(_ kind: CodexAppRuntimeNotice.Kind, _ title: String, _ detail: String, severity: CodexDiagnosticSeverity = .info) {
            result.append(.init(id: prefix+":"+kind.rawValue, kind: kind, title: title, detail: detail, severity: severity))
        }
        func value<T: Decodable>(_ method: String, _ type: T.Type) -> T? { try? turn.extensions[method]?.decode(type) }
        if let verification = value("model/verification", CodexSchemaModelVerificationNotification.self), !verification.verifications.isEmpty {
            add(.verification, "Model verification", verification.verifications.contains(.trustedAccessForCyber)
                ? "This turn requires trusted-access verification. Complete the verification request when prompted."
                : "This turn has a model verification requirement. Complete the runtime's verification request when prompted.", severity: .warning)
        }
        let started = value("modelProvider/authRecoveryStarted", CodexSchemaAuthRecoveryNotification.self)
        let completed = value("modelProvider/authRecoveryCompleted", CodexSchemaAuthRecoveryNotification.self)
        if started != nil || completed != nil {
            let active = turn.extensions["providerAuthRecoveryActive"] == .bool(true)
                || (turn.extensions["providerAuthRecoveryActive"] == nil && completed == nil)
            add(.authentication, active ? "Provider authentication recovery" : "Provider authentication recovered",
                active ? "Codex is recovering provider authentication for this turn." : "Codex completed provider authentication recovery.", severity: active ? .warning : .info)
        }
        if let safety = value("model/safetyBuffering/updated", CodexSchemaModelSafetyBufferingUpdatedNotification.self),
           safety.showBufferingUi, turn.status == .inProgress {
            add(.buffering, "Safety buffering", "Codex is checking this turn's output before releasing it.")
        }
        if let metadata = turn.moderationMetadata, metadata != .null {
            add(.moderation, "Moderation information", "Codex attached moderation information to this turn. Review any accompanying runtime warnings.")
        }
        if value("autoApprovalReview:strictReviewRequired", CodexSchemaStrictReviewRequiredNotification.self) != nil {
            add(.guardian, "Strict review required", "Codex escalated this turn to strict review. Review any pending approval before continuing.", severity: .warning)
        }
        if let reroute = value("model/rerouted", CodexSchemaModelReroutedNotification.self) {
            let reason = reroute.reason == .highRiskCyberActivity ? " Reason: high-risk cyber activity." : ""
            add(.rerouting, "Model rerouted", "Codex changed this turn from \(bounded(reroute.fromModel, limit: 160)) to \(bounded(reroute.toModel, limit: 160)).\(reason)")
        }
        return result
    }

    /// Only the schema's intended user-facing diagnostic fields reach the
    /// local panel. Native/provider payloads and the raw diagnostic detail do not.
    private static func diagnosticText(_ summary: String, _ details: String?, location: String? = nil) -> String {
        [Optional(bounded(summary)), details.map { bounded($0) }, location.map { "Location: " + bounded($0, limit: 300) }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func bounded(_ value: String, limit: Int = 1_000) -> String {
        let clean = value.unicodeScalars.map { scalar -> String in
            CharacterSet.controlCharacters.contains(scalar) && scalar.value != 10 && scalar.value != 9 ? " " : String(scalar)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return String(clean.prefix(limit)) + (clean.count > limit ? "…" : "")
    }
}
