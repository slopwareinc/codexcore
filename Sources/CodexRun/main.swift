import Foundation
import CodexCore

@main
struct CodexRun {
    private struct ProgressRenderState {
        var itemID: ItemID?
        var line: String?
    }

    static func main() async {
        setbuf(stdout, nil)
        print("\n🚀 Bootstrapping Native Swift Codex SDK Demonstration...")

        let currentDirectory = FileManager.default.currentDirectoryPath
        let config = CodexConfig(
            codexHome: .default,
            cwd: currentDirectory,
            clientName: "codex_run",
            clientTitle: "Codex Swift SDK CLI Demo",
            clientVersion: "1.0.0"
        )

        var codex: Codex?
        var thread: CodexThreadLease?

        do {
            print("🔌 Spawning local daemon subprocess and upgrading to JSON-RPC...")
            let connectedCodex = try await Codex(
                config: config,
                serverRequestHandler: autoApproveServerRequest
            )
            codex = connectedCodex
            print("✅ Initialize handshake negotiated successfully!")
            print("📁 Host workspace directory: \(currentDirectory)")

            print("🧵 Requesting conversation thread creation (thread/start)...")
            let activeThread = try await connectedCodex.startThread(.init(
                approvalPolicy: .init(.string("on-request")),
                approvalsReviewer: .autoReview,
                cwd: currentDirectory
            ))
            thread = activeThread
            print("✅ Thread registered: \(activeThread.id)")

            let prompt = "Please create a single-file interactive HTML/CSS/JS Todo Application with a gorgeous dark-mode user interface, and save it exactly as 'todo.html' in this working directory."
            print("📝 Submitting developer task to Codex (turn/start)...")
            print("👉 prompt: \(prompt)")

            let input = CodexSchemaUserInput(.dictionary([
                "type": .string("text"),
                "text": .string(prompt),
            ]))
            let turn = try await activeThread.startTurn(.init(
                cwd: currentDirectory,
                input: [input],
                threadID: activeThread.id.rawValue
            ))
            print("\n⏳ Turn running [\(turn.key.turnID)]. Tracking live progress from canonical state:")

            let observation = try await turn.observe(fields: [
                .turnStatus,
                .itemStructure,
                .itemLifecycle,
                .itemContent,
            ])
            let progressTask = Task {
                await trackProgress(for: turn, observation: observation)
            }

            let terminal: CodexTerminalTurn
            do {
                terminal = try await turn.awaitTerminal()
            } catch {
                await turn.cancel(observation)
                progressTask.cancel()
                await progressTask.value
                throw error
            }

            await turn.cancel(observation)
            progressTask.cancel()
            await progressTask.value
            printTerminalStatus(terminal.turn)

            let todoPath = "\(currentDirectory)/todo.html"
            if FileManager.default.fileExists(atPath: todoPath) {
                print("\n🏆 Success! 'todo.html' was successfully written onto your host machine!")

                if let content = try? String(contentsOfFile: todoPath, encoding: .utf8) {
                    print("\n--- TODO.HTML PREVIEW (first 800 chars) ---")
                    print(content.prefix(800))
                    print("... [truncated] ...\n")
                    print("📁 Open in browser: file://\(todoPath)")
                }
            } else {
                print("\n⚠️ Note: The task finished but no 'todo.html' was found in the workspace.")
                print("   Codex may have written it elsewhere, or the turn may have failed.")
            }

            await activeThread.close()
            thread = nil
            await connectedCodex.close()
            codex = nil
            print("🔌 Connection closed gracefully.")
        } catch {
            await thread?.close()
            await codex?.close()
            print("\n❌ Task execution failed with error: \(error)")
        }
    }

    private static func trackProgress(
        for turn: CodexTurnLease,
        observation: StateSnapshotObservation<CanonicalStateSnapshot>
    ) async {
        var renderState = ProgressRenderState()
        renderProgress(from: observation.seed, state: &renderState)

        for await _ in observation.signals {
            guard !Task.isCancelled else { break }

            guard let snapshot = try? await turn.snapshot(fields: [
                .turnStatus,
                .itemStructure,
                .itemLifecycle,
                .itemContent,
            ]) else {
                return
            }
            renderProgress(from: snapshot, state: &renderState)
        }
    }

    private static func renderProgress(
        from snapshot: CanonicalStateSnapshot,
        state: inout ProgressRenderState
    ) {
        guard let turn = snapshot.turns.values.first,
              let item = snapshot.items(in: turn.key).last,
              let line = progressLine(for: item),
              line != state.line
        else {
            return
        }

        if item.key.itemID != state.itemID {
            print("")
            state.itemID = item.key.itemID
        }
        state.line = line
        print("\r\(line)", terminator: "")
        fflush(stdout)
    }

    private static func progressLine(for item: CanonicalItem) -> String? {
        switch item.kind {
        case .agentMessage:
            let text = (CodexJSONCoercion.string(from: item.payload["text"]) ?? "")
                + item.liveOverlay.agentMessage.joined()
            return text.nilIfBlank.map { "🤖 Codex: ... \(tail($0))" }

        case .commandExecution:
            guard let command = CodexJSONCoercion.string(from: item.payload["command"])?.nilIfBlank else {
                return nil
            }
            return "🛠️ Shell execution: \(String(command.prefix(60)))..."

        case .reasoning:
            var text = CodexJSONCoercion.string(
                from: item.payload["summary"],
                dictionaryKeys: CodexJSONCoercion.defaultStringKeys,
                separator: " "
            ) ?? ""
            for index in item.liveOverlay.reasoningSummary.keys.sorted() {
                text += item.liveOverlay.reasoningSummary[index]?.joined() ?? ""
            }
            return text.nilIfBlank.map { "🧠 Thinking: ... \(tail($0))" }

        default:
            return nil
        }
    }

    private static func tail(_ text: String) -> String {
        String(text.suffix(60)).replacingOccurrences(of: "\n", with: " ")
    }

    private static func printTerminalStatus(_ turn: CanonicalTurn) {
        switch turn.status {
        case .completed:
            print("\n\n🎉 Turn completed successfully!")
        case .failed:
            let detail = turn.error?.message.nilIfBlank.map { ": \($0)" } ?? ""
            print("\n\n❌ Turn execution failed\(detail)!")
        case .interrupted:
            print("\n\n⚠️ Turn was interrupted.")
        case .inProgress, .unknown:
            print("\n\n⚠️ Turn waiter returned a non-terminal state: \(turn.status.rawValue)")
        }
    }

    /// This executable is a trusted, non-interactive SDK demonstration. Keep
    /// app-server request handling explicit at the session seam so the Core
    /// runtime never embeds a UI or automation approval policy.
    private static func autoApproveServerRequest(
        _ request: CodexParsedServerRequest
    ) async -> CodexServerRequestHandlerDecision {
        let result: CodexValidatedServerRequestResult

        switch request.body {
        case .commandApproval(let approval):
            let decision = approval.availableDecisions?.first(where: { $0 == .accept })
                ?? approval.availableDecisions?.first(where: { $0 == .acceptForSession })
                ?? approval.availableDecisions?.first
                ?? .accept
            result = .commandApproval(decision)

        case .fileChangeApproval:
            result = .fileChangeApproval(.accept)

        case .userInput:
            result = .userInput([:])

        case .mcpElicitation:
            result = .mcpElicitation(action: .decline, content: nil, metadata: nil)

        case .permissionsApproval(let approval):
            result = .permissions(
                permissions: .dictionary(approval.permissions),
                scope: .turn,
                strictAutoReview: nil
            )

        case .dynamicToolCall:
            result = .dynamicTool(success: false, contentItems: [])

        case .currentTime:
            result = .currentTime(unixSeconds: Int64(Date().timeIntervalSince1970))

        case .legacyApplyPatchApproval:
            result = .legacyApplyPatchApproval(.approved)

        case .legacyExecCommandApproval:
            result = .legacyExecCommandApproval(.approved)

        case .tokenRefresh, .attestation, .unknown:
            return .error(.init(
                code: -32_601,
                message: "CodexRun cannot satisfy \(request.body.method)"
            ))
        }

        return .result(result.jsonValue)
    }
}
