import Foundation
import CodexCore

enum CodexThreadFeatureSection: String, CaseIterable, Identifiable {
    case attachments = "Attachments"
    case memory = "Memory"
    case history = "History"
    case settings = "Settings"
    case queue = "Queue"
    case goal = "Goal"
    case search = "Find"
    case approvals = "Approvals"
    var id: String { rawValue }
}

/// The thread inspector owns this small, typed request boundary. It never sends
/// guessed method strings or mutates a second transcript store.
enum CodexThreadFeatureRequest: Sendable, Equatable {
    case attachments(CodexSchemaThreadAttachmentListParams)
    case addAttachment(CodexSchemaThreadAttachmentAddParams)
    case removeAttachment(CodexSchemaThreadAttachmentRemoveParams)
    case memoryStatus(CodexSchemaMemoryStatusParams)
    case resetMemory
    case memoryMode(CodexSchemaThreadMemoryModeSetParams)
    case read(CodexSchemaThreadReadParams)
    case timeline(CodexSchemaThreadTimelineListParams)
    case turns(CodexSchemaThreadTurnsListParams)
    case metadata(CodexSchemaThreadMetadataUpdateParams)
    case settings(CodexSchemaThreadSettingsUpdateParams)
    case delete(CodexSchemaThreadDeleteParams)
    case revert(CodexSchemaThreadRevertParams)
    case queue(CodexSchemaThreadQueueListParams)
    case reorderQueue(CodexSchemaThreadQueueReorderParams)
    case startQueue(CodexSchemaThreadQueueStartParams)
    case goal(CodexSchemaThreadGoalGetParams)
    case setGoal(CodexSchemaThreadGoalSetParams)
    case clearGoal(CodexSchemaThreadGoalClearParams)
    case occurrences(CodexSchemaThreadSearchOccurrencesParams)
    case loaded(CodexSchemaThreadLoadedListParams)
    case approveGuardian(CodexSchemaThreadApproveGuardianDeniedActionParams)
}

enum CodexThreadFeatureResponse: Sendable {
    case attachments(CodexSchemaThreadAttachmentListResponse)
    case attachment(CodexSchemaThreadAttachmentAddResponse)
    case memory(CodexSchemaMemoryStatusResponse)
    case thread(CodexSchemaThread)
    case timeline(CodexSchemaThreadTimelineListResponse)
    case turns(CodexSchemaThreadTurnsListResponse)
    case queue(CodexSchemaThreadQueueListResponse)
    case turn(CodexSchemaTurn)
    case goal(CodexSchemaThreadGoal?)
    case occurrences(CodexSchemaThreadSearchOccurrencesResponse)
    case loaded(CodexSchemaThreadLoadedListResponse)
    case mutation
}

enum CodexThreadFeatureInvalidation: Sendable {
    case attachments, settings, queue, guardian
}

protocol CodexThreadFeatureProvider: Sendable {
    func perform(_ request: CodexThreadFeatureRequest) async throws -> CodexThreadFeatureResponse
    func settings(threadID: String) async -> [String: CodexJSONValue]?
    func deniedReviews(threadID: String) async -> [CodexGuardianDeniedReview]
    func changes(threadID: String) async throws -> AsyncStream<CodexThreadFeatureInvalidation>
}

extension CodexThreadFeatureProvider {
    func settings(threadID: String) async -> [String: CodexJSONValue]? { nil }
    func deniedReviews(threadID: String) async -> [CodexGuardianDeniedReview] { [] }
    func changes(threadID: String) async throws -> AsyncStream<CodexThreadFeatureInvalidation> {
        AsyncStream { $0.finish() }
    }
}

struct CodexAppServerThreadFeatureProvider: CodexThreadFeatureProvider {
    let codex: Codex

    func perform(_ request: CodexThreadFeatureRequest) async throws -> CodexThreadFeatureResponse {
        switch request {
        case .attachments(let value): return .attachments(try await codex.perform(CodexRequest.threadAttachmentList(value)))
        case .addAttachment(let value): return .attachment(try await codex.perform(CodexRequest.threadAttachmentAdd(value)))
        case .removeAttachment(let value): _ = try await codex.perform(CodexRequest.threadAttachmentRemove(value))
        case .memoryStatus(let value): return .memory(try await codex.perform(CodexRequest.memoryStatus(value)))
        case .resetMemory: _ = try await codex.perform(CodexRequest.memoryReset())
        case .memoryMode(let value): _ = try await codex.perform(CodexRequest.threadMemoryModeSet(value))
        case .read(let value): return .thread(try await codex.perform(CodexRequest.threadRead(value)).thread)
        case .timeline(let value): return .timeline(try await codex.perform(CodexRequest.threadTimelineList(value)))
        case .turns(let value): return .turns(try await codex.perform(CodexRequest.threadTurnsList(value)))
        case .metadata(let value): return .thread(try await codex.perform(CodexRequest.threadMetadataUpdate(value)).thread)
        case .settings(let value): _ = try await codex.perform(CodexRequest.threadSettingsUpdate(value))
        case .delete(let value): _ = try await codex.perform(CodexRequest.threadDelete(value))
        case .revert(let value): return .thread(try await codex.perform(CodexRequest.threadRevert(value)).thread)
        case .queue(let value): return .queue(try await codex.perform(CodexRequest.threadQueueList(value)))
        case .reorderQueue(let value): _ = try await codex.perform(CodexRequest.threadQueueReorder(value))
        case .startQueue(let value): return .turn(try await codex.perform(CodexRequest.threadQueueStart(value)).turn)
        case .goal(let value): return .goal(try await codex.perform(CodexRequest.threadGoalGet(value)).goal)
        case .setGoal(let value): return .goal(try await codex.perform(CodexRequest.threadGoalSet(value)).goal)
        case .clearGoal(let value): _ = try await codex.perform(CodexRequest.threadGoalClear(value))
        case .occurrences(let value): return .occurrences(try await codex.perform(CodexRequest.threadSearchOccurrences(value)))
        case .loaded(let value): return .loaded(try await codex.perform(CodexRequest.threadLoadedList(value)))
        case .approveGuardian(let value): _ = try await codex.perform(CodexRequest.threadApproveGuardianDeniedAction(value))
        }
        return .mutation
    }

    func settings(threadID: String) async -> [String: CodexJSONValue]? {
        await codex.session.canonicalSnapshot(scope: .thread(ThreadID(threadID), fields: .threadSettings))
            .threads[ThreadID(threadID)]?.settings
    }

    func deniedReviews(threadID: String) async -> [CodexGuardianDeniedReview] {
        let snapshot = await codex.session.canonicalSnapshot(scope: .thread(.init(threadID), fields: [.turnMetadata, .extensions]))
        return snapshot.turns.values.filter { $0.key.threadID.rawValue == threadID }.flatMap { turn in
            turn.extensions.filter { $0.key.hasPrefix("autoApprovalReview:") }.compactMap {
                CodexGuardianDeniedReview(notification: $0.value, threadID: threadID, turnID: turn.key.turnID.rawValue)
            }
        }.sorted { $0.completedAtMs > $1.completedAtMs }.prefix(10).map { $0 }
    }

    func changes(threadID: String) async throws -> AsyncStream<CodexThreadFeatureInvalidation> {
        let id = ThreadID(threadID)
        let scope = StateObservationScope.thread(id, fields: [.threadMetadata, .threadSettings, .turnMetadata, .extensions])
        let observation = await codex.session.observe(scope: scope)
        let queue: AsyncThrowingStream<CodexSchemaThreadQueueChangedNotification, Error>
        do {
            queue = try await codex.session.observeThreadQueueChanges(threadID: threadID)
        } catch {
            await codex.session.cancelObservation(observation.id)
            throw error
        }
        let session = codex.session
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            let stateTask = Task {
                var previousSettings = observation.seed.threads[id]?.settings
                var previousAttachment = observation.seed.threads[id]?.metadata.extensions["thread/attachment/updated"]
                for await _ in observation.signals {
                    if Task.isCancelled { break }
                    let snapshot = await session.canonicalSnapshot(scope: scope)
                    let thread = snapshot.threads[id]
                    continuation.yield(.guardian)
                    let attachment = thread?.metadata.extensions["thread/attachment/updated"]
                    if attachment != previousAttachment {
                        previousAttachment = attachment
                        continuation.yield(.attachments)
                    }
                    if thread?.settings != previousSettings {
                        previousSettings = thread?.settings
                        continuation.yield(.settings)
                    }
                }
                await session.cancelObservation(observation.id)
            }
            let queueTask = Task {
                do {
                    for try await _ in queue {
                        if Task.isCancelled { break }
                        continuation.yield(.queue)
                    }
                } catch { /* Connection ownership and errors remain in the host. */ }
            }
            continuation.onTermination = { _ in stateTask.cancel(); queueTask.cancel() }
        }
    }
}

enum CodexThreadFeatureError: LocalizedError {
    case disconnected, unexpectedResponse, invalidResource(String), invalidSettings(String), invalidQueue
    var errorDescription: String? {
        switch self {
        case .disconnected: "Select a connected chat to manage its features."
        case .unexpectedResponse: "Codex returned an unexpected response. Refresh the chat and try again."
        case .invalidResource(let message), .invalidSettings(let message): message
        case .invalidQueue: "The queue changed. Refresh it before changing the order."
        }
    }
}

enum CodexThreadResourceKind: String, CaseIterable, Identifiable {
    case link = "Link", file = "File or folder", pullRequest = "Pull request"
    var id: String { rawValue }
}

struct CodexThreadResourceDraft {
    var kind: CodexThreadResourceKind = .link
    var title = ""
    var location = ""

    func parameters(threadID: String) throws -> CodexSchemaThreadAttachmentAddParams {
        let value = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 8_192, name.utf8.count <= 512,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw CodexThreadFeatureError.invalidResource("Enter a valid resource location and a title under 512 bytes.") }
        let type: String
        let identity: String
        var payload: [String: CodexJSONValue] = [:]
        switch kind {
        case .file:
            guard value.hasPrefix("/") else {
                throw CodexThreadFeatureError.invalidResource("Choose an absolute file or folder path.")
            }
            identity = URL(fileURLWithPath: value).standardizedFileURL.path
            type = "file"
            payload["path"] = .string(identity)
        case .link, .pullRequest:
            guard var components = URLComponents(string: value),
                  ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
                  let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil else {
                throw CodexThreadFeatureError.invalidResource("Enter an HTTP or HTTPS URL without embedded credentials.")
            }
            components.scheme = components.scheme?.lowercased()
            components.host = host.lowercased()
            components.fragment = nil
            if kind == .pullRequest {
                let parts = components.path.split(separator: "/")
                guard parts.count == 4, parts[2] == "pull", Int(parts[3]).map({ $0 > 0 }) == true else {
                    throw CodexThreadFeatureError.invalidResource("Enter a pull request URL ending in /owner/repository/pull/number.")
                }
                components.query = nil
                components.path = "/" + parts.joined(separator: "/")
            }
            guard let url = components.url else { throw CodexThreadFeatureError.invalidResource("The URL is invalid.") }
            identity = url.absoluteString
            type = kind == .pullRequest ? "pull_request" : "link"
            payload["url"] = .string(identity)
        }
        if !name.isEmpty { payload["title"] = .string(name) }
        return .init(attachmentType: type, identityKey: identity, payload: .dictionary(payload), threadID: threadID)
    }
}

struct CodexThreadSettingsDraft {
    var model = ""
    var effort = ""
    var personality = ""
    var serviceTier = ""
    var daybreak = ""
    var projectID = ""
    var disabledPluginIDs: Set<String> = []
    var updatesDisabledPlugins = false

    func parameters(threadID: String) throws -> CodexSchemaThreadSettingsUpdateParams {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let tier = serviceTier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.utf8.count <= 512, tier.utf8.count <= 128,
              !model.contains(where: { $0.isNewline }), !tier.contains(where: { $0.isNewline }) else {
            throw CodexThreadFeatureError.invalidSettings("Model and service tier must each fit on one line.")
        }
        return .init(
            disabledPluginIDs: updatesDisabledPlugins ? disabledPluginIDs.sorted() : nil,
            effort: effort.isEmpty ? nil : CodexSchemaReasoningEffort(.string(effort)),
            model: model.isEmpty ? nil : model,
            personality: personality.isEmpty ? nil : CodexSchemaPersonality(rawValue: personality),
            serviceTier: tier.isEmpty ? nil : tier,
            threadID: threadID
        )
    }
}

struct CodexThreadGoalDraft {
    var objective = ""
    var tokenBudget = ""

    func parameters(threadID: String) throws -> CodexSchemaThreadGoalSetParams {
        let objective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let budgetText = tokenBudget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty, objective.utf8.count <= 64 * 1_024 else {
            throw CodexThreadFeatureError.invalidSettings("Enter an objective under 64 KiB.")
        }
        let budget: Int?
        if budgetText.isEmpty { budget = nil }
        else {
            guard let value = Int(budgetText), value > 0 else {
                throw CodexThreadFeatureError.invalidSettings("Token budget must be a positive whole number.")
            }
            budget = value
        }
        return .init(objective: objective, status: .active, threadID: threadID, tokenBudget: budget)
    }
}

struct CodexThreadTimelineRow: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let raw: CodexJSONValue

    init(value: CodexSchemaThreadTimelineEntry, ordinal: Int) {
        raw = value.rawValue
        let object = raw.objectValue ?? [:]
        let kind = CodexJSONCoercion.string(in: object, keys: ["type"]) ?? "Event"
        let turn = object["turn"]?.objectValue ?? [:]
        let turnID = CodexJSONCoercion.string(in: turn, keys: ["id"]) ?? CodexJSONCoercion.string(in: object, keys: ["turnId"])
        id = CodexJSONCoercion.string(in: object, keys: ["id"]) ?? "\(kind):\(turnID ?? String(ordinal))"
        title = kind.replacingOccurrences(of: "_", with: " ").capitalized
        detail = CodexJSONCoercion.string(in: object, keys: ["text"])
            ?? CodexJSONCoercion.string(in: object, keys: ["transcript"])
            ?? turnID.map { "Turn \($0)" }
            ?? "Recorded thread event"
    }
}

struct CodexThreadOccurrenceIdentity: Hashable {
    let turnID: String
    let itemID: String
    let snippet: String
    let start: Int
    let end: Int

    init(_ value: CodexSchemaThreadSearchOccurrence) {
        turnID = value.turnID; itemID = value.itemID; snippet = value.snippet
        start = value.snippetMatchRange.start; end = value.snippetMatchRange.end
    }
}
