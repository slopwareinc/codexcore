import CodexCore
import CodexCoreUI
import Foundation

extension CodexCoreAppModel {
    static let realtimeVoiceFeatureConfig: CodexJSONValue = .dictionary([
        "features.realtime_conversation": .bool(true),
    ])

    static let voiceTaskToolSpecs: [CodexSchemaDynamicToolSpec] = [
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
        voiceTaskToolSpec(
            name: "fork_thread",
            description: "Fork an existing local task with its conversation context.",
            properties: [
                "threadId": stringProperty("The source task/thread identifier."),
                "context": .dictionary([
                    "type": .string("string"),
                    "enum": .array([.string("local"), .string("same_worktree")]),
                    "description": .string("Local keeps the current project context; same_worktree keeps the source worktree context."),
                ]),
                "ephemeral": .dictionary([
                    "type": .string("boolean"),
                    "description": .string("Whether the fork should be ephemeral, as side chats are."),
                ]),
            ],
            required: ["threadId"]
        ),
        voiceTaskToolSpec(
            name: "get_thread_status",
            description: "Read canonical lifecycle and latest-turn status for one task.",
            properties: ["threadId": stringProperty("The task/thread identifier.")],
            required: ["threadId"]
        ),
        voiceTaskToolSpec(
            name: "wait_threads",
            description: "Wait for one to eight tasks to finish and return their result text or errors.",
            properties: [
                "threadIds": .dictionary([
                    "type": .string("array"),
                    "items": .dictionary(["type": .string("string")]),
                    "minItems": .int(1),
                    "maxItems": .int(8),
                ]),
                "timeoutSeconds": .dictionary([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "maximum": .int(120),
                ]),
            ],
            required: ["threadIds"]
        ),
        voiceTaskToolSpec(
            name: "interrupt_thread",
            description: "Interrupt a task and every running descendant task, leaf-first.",
            properties: ["threadId": stringProperty("The root task/thread identifier.")],
            required: ["threadId"]
        ),
        voiceTaskToolSpec(
            name: "set_thread_archived",
            description: "Archive or unarchive a task and its recursive descendants.",
            properties: [
                "threadId": stringProperty("The root task/thread identifier."),
                "archived": .dictionary(["type": .string("boolean")]),
            ],
            required: ["threadId", "archived"]
        ),
    ]

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
            dynamicTools: Self.voiceTaskToolSpecs,
            historyMode: CodexSchemaThreadHistoryMode(
                rawValue: newThreadHistoryMode.rawValue
            ),
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
              request.scope.threadID != nil,
              Self.voiceTaskToolNames.contains(request.tool),
              let codex
        else {
            return .pending
        }

        do {
            let content: CodexJSONValue
            switch request.tool {
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

            case "fork_thread":
                let threadID = try request.arguments.requiredString(for: "threadId")
                let context = request.arguments.string(for: "context") ?? "local"
                guard context == "local" || context == "same_worktree" else {
                    throw CodexVoiceTaskToolError.unsupportedTarget(context)
                }
                let response = try await codex.perform(CodexRequest.threadRead(.init(
                    includeTurns: false,
                    threadID: threadID
                )))
                let cwd = response.thread.cwd.rawValue.stringValue ?? workspacePath
                let roots = workspaceRoots(containing: cwd)
                let service = CodexThreadGraphService(codex: codex)
                let lease = try await service.fork(
                    .init(hostID: "local", threadID: ThreadID(threadID)),
                    cwd: cwd,
                    runtimeWorkspaceRoots: roots,
                    ephemeral: request.arguments.boolean(for: "ephemeral") ?? false
                )
                content = .dictionary([
                    "hostId": .string("local"),
                    "threadId": .string(lease.id.rawValue),
                    "sourceThreadId": .string(threadID),
                    "context": .string(context),
                ])
                await lease.close()

            case "get_thread_status":
                let threadID = try request.arguments.requiredString(for: "threadId")
                let snapshot = await codex.session.canonicalSnapshot()
                let key = CodexThreadGraphKey(hostID: "local", threadID: ThreadID(threadID))
                let node = CodexThreadGraphProjector.project(snapshot, hostID: "local").nodes[key]
                let latest = snapshot.turns(in: key.threadID).last
                content = .dictionary([
                    "hostId": .string("local"),
                    "threadId": .string(threadID),
                    "turnId": latest.map { .string($0.key.turnID.rawValue) } ?? .null,
                    "turnStatus": latest.map { .string($0.status.rawValue) } ?? .null,
                    "agentStatus": node?.lifecycle.map { .string($0.rawValue) } ?? .null,
                    "message": (node?.errorMessage ?? node?.resultMessage).map(CodexJSONValue.string) ?? .null,
                    "childThreadIds": .array((node?.children ?? []).map { .string($0.threadID.rawValue) }),
                ])

            case "wait_threads":
                let ids = try request.arguments.requiredStringArray(for: "threadIds")
                guard (1...8).contains(ids.count) else {
                    throw CodexVoiceTaskToolError.invalidArgument("threadIds must contain 1...8 ids")
                }
                let seconds = min(max(request.arguments.integer(for: "timeoutSeconds") ?? 120, 1), 120)
                let service = CodexThreadGraphService(codex: codex)
                let results = try await service.wait(
                    for: ids.map { .init(hostID: "local", threadID: ThreadID($0)) },
                    timeout: .seconds(seconds)
                )
                content = .array(results.map { result in
                    .dictionary([
                        "hostId": .string(result.thread.hostID),
                        "threadId": .string(result.thread.threadID.rawValue),
                        "turnId": result.turnID.map { .string($0.rawValue) } ?? .null,
                        "turnStatus": result.status.map { .string($0.rawValue) } ?? .null,
                        "agentStatus": result.lifecycle.map { .string($0.rawValue) } ?? .null,
                        "result": result.result.map(CodexJSONValue.string) ?? .null,
                        "error": result.error.map(CodexJSONValue.string) ?? .null,
                    ])
                })

            case "interrupt_thread":
                let threadID = try request.arguments.requiredString(for: "threadId")
                let report = await CodexThreadGraphService(codex: codex).interruptRecursively(
                    .init(hostID: "local", threadID: ThreadID(threadID))
                )
                content = Self.voiceOperationReport(report)

            case "set_thread_archived":
                let threadID = try request.arguments.requiredString(for: "threadId")
                let archived = try request.arguments.requiredBoolean(for: "archived")
                let report = await CodexThreadGraphService(codex: codex).setArchivedRecursively(
                    .init(hostID: "local", threadID: ThreadID(threadID)),
                    archived: archived
                )
                content = Self.voiceOperationReport(report)

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

    private static let voiceTaskToolNames: Set<String> = [
        "list_projects",
        "create_thread",
        "list_threads",
        "read_thread",
        "send_message_to_thread",
        "fork_thread",
        "get_thread_status",
        "wait_threads",
        "interrupt_thread",
        "set_thread_archived",
    ]

    private static func voiceTaskToolSpec(
        name: String,
        description: String,
        properties: [String: CodexJSONValue],
        required: [String] = []
    ) -> CodexSchemaDynamicToolSpec {
        CodexSchemaDynamicToolSpec(.dictionary([
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

    private static func stringProperty(_ description: String) -> CodexJSONValue {
        .dictionary(["type": .string("string"), "description": .string(description)])
    }

    private static func voiceOperationReport(
        _ report: CodexThreadGraphOperationReport
    ) -> CodexJSONValue {
        .dictionary([
            "complete": .bool(report.isComplete),
            "attemptedThreadIds": .array(report.attempted.map { .string($0.threadID.rawValue) }),
            "succeededThreadIds": .array(report.succeeded.map { .string($0.threadID.rawValue) }),
            "failures": .array(report.failures.map { failure in
                .dictionary([
                    "threadId": .string(failure.thread.threadID.rawValue),
                    "error": .string(failure.message),
                ])
            }),
        ])
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
    case unknownProject(String)
    case unsupportedTarget(String)
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            "Missing required argument: \(name)"
        case .unknownProject(let id):
            "Unknown project: \(id). Call list_projects and use a returned projectId."
        case .unsupportedTarget(let type):
            "Unsupported task target: \(type)"
        case .invalidArgument(let message):
            message
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

    func boolean(for key: String) -> Bool? {
        guard case .dictionary(let object) = self,
              case .bool(let value)? = object[key] else { return nil }
        return value
    }

    func requiredBoolean(for key: String) throws -> Bool {
        guard let value = boolean(for: key) else {
            throw CodexVoiceTaskToolError.missingArgument(key)
        }
        return value
    }

    func requiredStringArray(for key: String) throws -> [String] {
        guard case .dictionary(let object) = self,
              case .array(let values)? = object[key]
        else { throw CodexVoiceTaskToolError.missingArgument(key) }
        let strings = values.compactMap { value -> String? in
            guard case .string(let string) = value, !string.isEmpty else { return nil }
            return string
        }
        guard strings.count == values.count else {
            throw CodexVoiceTaskToolError.invalidArgument("\(key) must contain only non-empty strings")
        }
        return strings
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
