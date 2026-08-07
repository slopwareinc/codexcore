import CodexCore
import CodexCoreUI
import Foundation

extension CodexCoreAppModel {
    /// The app-server schema carries the source on a thread start, while the
    /// official host also carries an internal thread-start kind through its
    /// dynamic-tool request. Keep both dimensions explicit so a normal start
    /// can never inherit realtime Voice tools just because it shares a builder.
    enum DynamicToolsThreadStartKind: Sendable, Equatable {
        case normal
        case realtimeVoice
    }

    static let realtimeVoiceFeatureConfig: CodexJSONValue = .dictionary([
        "features.realtime_conversation": .bool(true),
    ])

    static let realtimeVoiceTaskToolSpecs: [CodexSchemaDynamicToolSpec] = [
        voiceTaskToolSpec(
            name: "end_realtime_voice_call",
            description: "End the current voice chat. Only call this tool if the user explicitly asks to end the voice chat.",
            properties: [:]
        ),
        voiceTaskToolSpec(
            name: "list_projects",
            description: "List saved local projects available for creating a separate Codex task.",
            properties: [:]
        ),
        voiceTaskToolSpec(
            name: "create_thread",
            description: "Create a separate top-level task only when the user explicitly asks for one. Creation is non-blocking.",
            properties: [
                "prompt": .dictionary([
                    "type": .string("string"),
                    "description": .string("Initial prompt for the new task."),
                ]),
                "target": .dictionary([
                    "description": .string("Where to create the task."),
                    "anyOf": .array([
                        .dictionary([
                            "type": .string("object"),
                            "additionalProperties": .bool(false),
                            "properties": .dictionary([
                                "type": .dictionary([
                                    "type": .string("string"),
                                    "enum": .array([.string("project")]),
                                ]),
                                "projectId": .dictionary([
                                    "type": .string("string"),
                                    "description": .string("Project id returned by list_projects."),
                                ]),
                                "environment": .dictionary([
                                    "type": .string("object"),
                                    "description": .string("Use local to run in the saved project."),
                                    "properties": .dictionary([
                                        "type": .dictionary([
                                            "type": .string("string"),
                                            "enum": .array([.string("local")]),
                                        ]),
                                    ]),
                                    "required": .array([.string("type")]),
                                    "additionalProperties": .bool(false),
                                ]),
                            ]),
                            "required": .array([
                                .string("type"),
                                .string("projectId"),
                                .string("environment"),
                            ]),
                        ]),
                        .dictionary([
                            "type": .string("object"),
                            "additionalProperties": .bool(false),
                            "properties": .dictionary([
                                "type": .dictionary([
                                    "type": .string("string"),
                                    "enum": .array([.string("projectless")]),
                                ]),
                                "directoryName": .dictionary([
                                    "type": .string("string"),
                                    "description": .string("Optional projectless output directory name."),
                                ]),
                            ]),
                            "required": .array([.string("type")]),
                        ]),
                    ]),
                ]),
                "model": .dictionary([
                    "type": .string("string"),
                    "description": .string("Optional model override. Omit to use the configured default."),
                ]),
                "thinking": .dictionary([
                    "type": .string("string"),
                    "description": .string("Optional reasoning effort override."),
                ]),
            ],
            required: ["prompt", "target"]
        ),
        voiceTaskToolSpec(
            name: "list_threads",
            description: "List recent top-level Codex tasks so the current task can inspect or coordinate them.",
            properties: [
                "limit": .dictionary([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "maximum": .int(100),
                    "description": .string("Maximum tasks to return. Defaults to 30."),
                ]),
            ]
        ),
        voiceTaskToolSpec(
            name: "read_thread",
            description: "Read one Codex task, including its transcript turns.",
            properties: [
                "threadId": .dictionary([
                    "type": .string("string"),
                    "description": .string("The task/thread identifier."),
                ]),
            ],
            required: ["threadId"]
        ),
        voiceTaskToolSpec(
            name: "send_message_to_thread",
            description: "Send an instruction to another top-level Codex task and let it run independently.",
            properties: [
                "threadId": .dictionary([
                    "type": .string("string"),
                    "description": .string("The target task/thread identifier."),
                ]),
                "prompt": .dictionary([
                    "type": .string("string"),
                    "description": .string("The instruction to send."),
                ]),
            ],
            required: ["threadId", "prompt"]
        ),
    ]

    /// Compatibility name for callers that only need to inspect the Voice
    /// inventory. Production startup paths use the explicitly gated name.
    static let voiceTaskToolSpecs = realtimeVoiceTaskToolSpecs

    /// Dynamic tools are a capability of a realtime Voice root, not a property
    /// of a normal thread or of a regular child task launched from Voice.
    static func dynamicToolsForThreadStart(
        threadSource: String?,
        threadStartKind: DynamicToolsThreadStartKind
    ) -> [CodexSchemaDynamicToolSpec]? {
        guard threadSource == "realtime_voice",
              threadStartKind == .realtimeVoice
        else {
            return nil
        }
        return realtimeVoiceTaskToolSpecs
    }

    /// Builds the realtime Voice root with both official gating dimensions set.
    /// `threadStartKind` is not part of the pinned generated schema, so this
    /// host-side policy keeps it paired with the wire `threadSource`.
    func realtimeVoiceThreadStartParametersForCurrentDraft() throws -> CodexSchemaThreadStartParams {
        var parameters = try threadStartParametersForCurrentDraft()
        parameters.config = Self.realtimeVoiceFeatureConfig
        parameters.threadSource = CodexSchemaThreadSource(.string("realtime_voice"))
        parameters.dynamicTools = Self.dynamicToolsForThreadStart(
            threadSource: "realtime_voice",
            threadStartKind: .realtimeVoice
        )
        return parameters
    }

    /// Builds a regular child task started from Voice. It must not inherit the
    /// realtime-only tools; only the realtime Voice root uses the gated builder
    /// below.
    func voiceThreadStartParameters(
        wire: CodexTaskWireSelection,
        permissionConfiguration: CodexPermissionProfileWireConfiguration,
        cwd: String,
        roots: [String],
        developerInstructions: String?
    ) -> CodexSchemaThreadStartParams {
        var parameters = wire.applying(to: CodexSchemaThreadStartParams(
            cwd: cwd,
            developerInstructions: developerInstructions,
            historyMode: CodexSchemaThreadHistoryMode(
                rawValue: newThreadHistoryMode.rawValue
            ),
            multiAgentMode: Self.defaultMultiAgentMode,
            runtimeWorkspaceRoots: roots.map {
                CodexSchemaAbsolutePathBuf(.string($0))
            }
        ))
        permissionConfiguration.apply(to: &parameters)
        return parameters
    }

    func voiceThreadStartParameters(
        wire: CodexTaskWireSelection,
        cwd: String,
        roots: [String],
        developerInstructions: String?
    ) -> CodexSchemaThreadStartParams {
        voiceThreadStartParameters(
            wire: wire,
            permissionConfiguration: .init(permissions: nil),
            cwd: cwd,
            roots: roots,
            developerInstructions: developerInstructions
        )
    }

    func voiceThreadResumeParameters(
        wire: CodexTaskWireSelection,
        cwd: String,
        roots: [String],
        threadID: String
    ) -> CodexSchemaThreadResumeParams {
        wire.applying(to: CodexSchemaThreadResumeParams(
            cwd: cwd,
            runtimeWorkspaceRoots: roots.map {
                CodexSchemaAbsolutePathBuf(.string($0))
            },
            threadID: threadID
        ))
    }

    func voiceTurnStartParameters(
        wire: CodexTaskWireSelection,
        permissionConfiguration: CodexPermissionProfileWireConfiguration?,
        cwd: String,
        roots: [String],
        prompt: String,
        threadID: String,
        clientUserMessageID: String
    ) -> CodexSchemaTurnStartParams {
        var parameters = wire.applying(to: CodexSchemaTurnStartParams(
            clientUserMessageID: clientUserMessageID,
            cwd: cwd,
            input: [CodexSchemaUserInput(CodexInput.text(prompt).jsonValue)],
            multiAgentMode: Self.defaultMultiAgentMode,
            runtimeWorkspaceRoots: roots.map {
                CodexSchemaAbsolutePathBuf(.string($0))
            },
            threadID: threadID
        ))
        permissionConfiguration?.apply(to: &parameters)
        return parameters
    }

    func voiceTurnStartParameters(
        wire: CodexTaskWireSelection,
        cwd: String,
        roots: [String],
        prompt: String,
        threadID: String,
        clientUserMessageID: String
    ) -> CodexSchemaTurnStartParams {
        voiceTurnStartParameters(
            wire: wire,
            permissionConfiguration: nil,
            cwd: cwd,
            roots: roots,
            prompt: prompt,
            threadID: threadID,
            clientUserMessageID: clientUserMessageID
        )
    }

    func voiceThreadProvenance(
        for wire: CodexTaskWireSelection
    ) -> CodexModelPreference {
        let ambientWire = configurationSession.wireSelection
        let sourcePreference = currentThreadID
            .flatMap { modelPreferenceByThread[$0] }
            ?? lastManualModelPreference
        return CodexModelPreference(
            modelID: wire.modelIdentifier,
            serviceTierID: wire.serviceTier,
            isServiceTierExplicit:
                wire.modelIdentifier == ambientWire.modelIdentifier
                && sourcePreference?.isServiceTierExplicit == true
        )
    }

    func handleVoiceTaskToolRequest(
        _ parsed: CodexParsedServerRequest
    ) async -> CodexServerRequestHandlerDecision {
        if case .attestation = parsed.body {
            let token = await CodexAppAttestation.shared.token()
            CodexVoiceLog.write(
                "attestation.generate.complete",
                level: .notice,
                fields: ["tokenBytes": String(token.utf8.count)]
            )
            return .result(.dictionary(["token": .string(token)]))
        }

        guard case .dynamicToolCall(let request) = parsed.body,
              let threadID = request.scope.threadID,
              Self.realtimeVoiceTaskToolNames.contains(request.tool),
              isRealtimeVoiceTaskThread(threadID),
              let codex
        else {
            return .pending
        }

        do {
            let content: CodexJSONValue
            switch request.tool {
            case "end_realtime_voice_call":
                guard voiceSession.threadID == request.scope.threadID else {
                    throw CodexVoiceTaskToolError.notCurrentVoiceThread
                }
                await stopVoiceChat()
                content = .dictionary(["ended": .bool(true)])

            case "list_projects":
                content = .array(recentProjects.map { project in
                    .dictionary([
                        "projectId": .string(project.id),
                        "name": .string(project.displayName),
                        "path": .string(project.workspacePath),
                        "sourceFolders": .array(project.sourceFolders.map(CodexJSONValue.string)),
                        "isGitRepository": .bool(
                            FileManager.default.fileExists(
                                atPath: URL(fileURLWithPath: project.workspacePath)
                                    .appendingPathComponent(".git").path
                            )
                        ),
                    ])
                })

            case "create_thread":
                let prompt = try request.arguments.requiredString(for: "prompt")
                let target = try request.arguments.requiredObject(for: "target")
                let targetType = try target.requiredString(for: "type")
                let wire = configurationSession.wireSelection.overriding(
                    model: request.arguments.string(for: "model"),
                    effort: request.arguments.string(for: "thinking")
                )

                let cwd: String
                let roots: [String]
                let developerInstructions: String?
                let isProjectless: Bool
                switch targetType {
                case "projectless":
                    let paths = try CodexProjectlessThreadPaths.create()
                    cwd = paths.cwd
                    roots = [paths.workspaceRoot]
                    developerInstructions = paths.developerInstructions
                    isProjectless = true
                case "project":
                    let projectID = try target.requiredString(for: "projectId")
                    guard let project = recentProjects.first(where: { $0.id == projectID }) else {
                        throw CodexVoiceTaskToolError.unknownProject(projectID)
                    }
                    cwd = project.workspacePath
                    roots = project.sourceFolders
                    developerInstructions = nil
                    isProjectless = false
                default:
                    throw CodexVoiceTaskToolError.unsupportedTarget(targetType)
                }

                let permissionConfiguration = configurationSession
                    .newThreadApprovalSelection
                    .permissionProfileWireConfiguration
                let lease = try await codex.startThread(voiceThreadStartParameters(
                    wire: wire,
                    permissionConfiguration: permissionConfiguration,
                    cwd: cwd,
                    roots: roots,
                    developerInstructions: developerInstructions
                ))
                let provenance = voiceThreadProvenance(for: wire)
                hydrateModelPreference(
                    for: lease.id.rawValue,
                    modelID: lease.modelIdentifier,
                    serviceTierID: lease.serviceTier,
                    provenance: provenance
                )
                if isProjectless {
                    projectlessThreadIDs.insert(lease.id.rawValue)
                    CodexProjectlessThreadStorage.save(
                        projectlessThreadIDs,
                        to: preferenceStore
                    )
                }
                let turn = try await lease.startTurn(voiceTurnStartParameters(
                    wire: wire,
                    permissionConfiguration: permissionConfiguration,
                    cwd: cwd,
                    roots: roots,
                    prompt: prompt,
                    threadID: lease.id.rawValue,
                    clientUserMessageID: UUID().uuidString
                ))
                content = .dictionary([
                    "threadId": .string(lease.id.rawValue),
                    "hostId": .string("local"),
                    "turnId": .string(turn.key.turnID.rawValue),
                    "status": .string("started"),
                ])
                Task {
                    _ = try? await turn.awaitTerminal()
                    await lease.close()
                    await self.refreshRecentChats()
                }

            case "list_threads":
                let limit = min(max(request.arguments.integer(for: "limit") ?? 30, 1), 100)
                let response = try await codex.perform(CodexRequest.threadList(.init(
                    archived: false,
                    limit: limit,
                    sortDirection: .desc,
                    sortKey: .recencyAt
                )))
                let summaries = response.data
                    .filter { $0.parentThreadID == nil && !$0.ephemeral }
                    .map { thread in
                        CodexVoiceTaskSummary(
                            id: thread.id,
                            name: thread.name,
                            preview: thread.preview,
                            cwd: thread.cwd.rawValue.stringValue,
                            updatedAt: thread.updatedAt
                        )
                    }
                content = try CodexJSONValue(encoding: summaries)

            case "read_thread":
                let threadID = try request.arguments.requiredString(for: "threadId")
                let response = try await codex.perform(CodexRequest.threadRead(.init(
                    includeTurns: true,
                    threadID: threadID
                )))
                content = try CodexJSONValue(encoding: response.thread)

            case "send_message_to_thread":
                let threadID = try request.arguments.requiredString(for: "threadId")
                let message = try request.arguments.requiredString(for: "prompt")
                let response = try await codex.perform(CodexRequest.threadRead(.init(
                    includeTurns: false,
                    threadID: threadID
                )))
                let cwd = response.thread.cwd.rawValue.stringValue ?? workspacePath
                let roots: [String]
                if projectlessThreadIDs.contains(threadID),
                   let paths = CodexProjectlessThreadPaths(resumingCWD: cwd) {
                    roots = [paths.workspaceRoot]
                } else {
                    roots = workspaceRoots(containing: cwd)
                }
                let resumeWire = taskWireSelection(
                    for: threadID,
                    explicitTierOnly: true
                )
                let lease = try await codex.resumeThread(voiceThreadResumeParameters(
                    wire: resumeWire,
                    cwd: cwd,
                    roots: roots,
                    threadID: threadID
                ))
                hydrateModelPreference(
                    for: threadID,
                    modelID: lease.modelIdentifier,
                    serviceTierID: lease.serviceTier
                )
                let targetWire = taskWireSelection(for: threadID).omittingEffort()
                let turn = try await lease.startTurn(voiceTurnStartParameters(
                    wire: targetWire,
                    permissionConfiguration: nil,
                    cwd: cwd,
                    roots: roots,
                    prompt: message,
                    threadID: threadID,
                    clientUserMessageID: UUID().uuidString
                ))
                let result: CodexJSONValue = .dictionary([
                    "threadId": .string(threadID),
                    "turnId": .string(turn.key.turnID.rawValue),
                    "status": .string("started"),
                ])
                Task {
                    _ = try? await turn.awaitTerminal()
                    await lease.close()
                }
                content = result

            default:
                return .pending
            }
            return Self.voiceTaskToolResult(success: true, content: content)
        } catch {
            return Self.voiceTaskToolResult(
                success: false,
                content: .dictionary([
                    "error": .string(CodexErrorFormat.localizedDescription(error)),
                ])
            )
        }
    }

    private func workspaceRoots(containing cwd: String) -> [String] {
        recentProjects.first(where: { $0.contains(workspacePath: cwd) })?.sourceFolders
            ?? [CodexProjectSummary.normalizedPath(cwd)]
    }

    private static let realtimeVoiceTaskToolNames: Set<String> = [
        "end_realtime_voice_call",
        "list_projects",
        "create_thread",
        "list_threads",
        "read_thread",
        "send_message_to_thread",
    ]

    /// A dynamic call is accepted only for the active realtime Voice thread.
    /// The sidebar source covers resumed/history threads; the local set covers
    /// a newly-created Voice root before the thread index has refreshed.
    private func isRealtimeVoiceTaskThread(_ threadID: String) -> Bool {
        guard voiceSession.isActive, voiceSession.threadID == threadID else {
            return false
        }
        if realtimeVoiceThreadIDs.contains(threadID) {
            return true
        }
        return allSidebarChats.first(where: { $0.id == threadID })?.threadSource == "realtime_voice"
    }

    private static func voiceTaskToolSpec(
        name: String,
        description: String,
        properties: [String: CodexJSONValue],
        required: [String] = []
    ) -> CodexSchemaDynamicToolSpec {
        CodexSchemaDynamicToolSpec(.dictionary([
            "type": .string("function"),
            "name": .string(name),
            "description": .string(description),
            "inputSchema": .dictionary([
                "type": .string("object"),
                "properties": .dictionary(properties),
                "required": .array(required.map(CodexJSONValue.string)),
                "additionalProperties": .bool(false),
            ]),
        ]))
    }

    private static func voiceTaskToolResult(
        success: Bool,
        content: CodexJSONValue
    ) -> CodexServerRequestHandlerDecision {
        let rendered: String
        if let data = try? JSONEncoder().encode(content),
           let string = String(data: data, encoding: .utf8) {
            rendered = string
        } else {
            rendered = String(describing: content)
        }
        return .result(CodexValidatedServerRequestResult.dynamicTool(
            success: success,
            contentItems: [.inputText(rendered)]
        ).jsonValue)
    }
}

private struct CodexVoiceTaskSummary: Encodable {
    let id: String
    let name: String?
    let preview: String
    let cwd: String?
    let updatedAt: Int
}

private enum CodexVoiceTaskToolError: LocalizedError {
    case missingArgument(String)
    case notCurrentVoiceThread
    case unknownProject(String)
    case unsupportedTarget(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            "Missing required argument: \(name)"
        case .notCurrentVoiceThread:
            "This tool is only available on the active Voice task."
        case .unknownProject(let id):
            "Unknown project: \(id). Call list_projects and use a returned projectId."
        case .unsupportedTarget(let type):
            "Unsupported task target: \(type)"
        }
    }
}

private extension CodexJSONValue {
    func requiredString(for key: String) throws -> String {
        guard case .dictionary(let object) = self,
              case .string(let value)? = object[key],
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CodexVoiceTaskToolError.missingArgument(key)
        }
        return value
    }

    func integer(for key: String) -> Int? {
        guard case .dictionary(let object) = self else { return nil }
        switch object[key] {
        case .int(let value): return value
        case .double(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    func requiredObject(for key: String) throws -> CodexJSONValue {
        guard case .dictionary(let object) = self,
              case .dictionary(let value)? = object[key]
        else {
            throw CodexVoiceTaskToolError.missingArgument(key)
        }
        return .dictionary(value)
    }

    func string(for key: String) -> String? {
        guard case .dictionary(let object) = self,
              case .string(let value)? = object[key],
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}
