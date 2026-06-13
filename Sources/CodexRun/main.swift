import Foundation
import CodexCore

@main
struct CodexRun {
    static func main() async {
        setbuf(stdout, nil)
        print("\n🚀 Bootstrapping Native Swift Codex SDK Demonstration...")

        let currentDir = FileManager.default.currentDirectoryPath
        let config = CodexConfig(
            cwd: currentDir,
            environment: ["CODEX_HOME": defaultCodexHome()],
            clientName: "codex_run",
            clientTitle: "Codex Swift SDK CLI Demo",
            clientVersion: "1.0.0",
            // Headless demo: approve escalations automatically. Interactive
            // apps should use `.ask` and resolve via Codex.respondToApproval.
            approvalPolicy: .autoApprove
        )

        var codex: Codex?

        do {
            print("🔌 Spawning local daemon subprocess and upgrading to JSON-RPC...")
            let connectedCodex = try await Codex(config: config)
            codex = connectedCodex
            print("✅ Initialize handshake negotiated successfully!")

            // Set working directory to the project workspace
            print("📁 Host workspace directory: \(currentDir)")

            print("🧵 Requesting conversation thread creation (thread/start)...")
            let thread = try await connectedCodex.threadStart(cwd: currentDir)
            print("✅ Thread registered: \(thread.id)")

            let prompt = "Please create a single-file interactive HTML/CSS/JS Todo Application with a gorgeous dark-mode user interface, and save it exactly as 'todo.html' in this working directory."
            print("📝 Submitting developer task to Codex (turn/start)...")
            print("👉 prompt: \(prompt)")

            let handle = try await thread.turn([.text(prompt)], cwd: currentDir)
            let turnId = handle.id
            print("\n⏳ Turn running [\(turnId)]. Tracking live progress from daemon:")

            // Poll state until turn completes
            var turnActive = true
            var lastPrintedItem = ""

            while turnActive {
                try? await Task.sleep(for: .milliseconds(500))

                await MainActor.run {
                    guard let activeThread = connectedCodex.store.activeThread,
                          let turn = activeThread.turns.first(where: { $0.id == turnId }) else { return }

                    if turn.status == .completed {
                        print("\n\n🎉 Turn completed successfully!")
                        turnActive = false
                    } else if turn.status == .failed {
                        print("\n\n❌ Turn execution failed!")
                        turnActive = false
                    } else {
                        // Print latest streaming details
                        if let lastItem = turn.items.last {
                            let itemId = lastItem.id
                            if itemId != lastPrintedItem {
                                lastPrintedItem = itemId
                                print("") // New line for new items
                            }

                            switch lastItem {
                            case .assistantMessage(_, let text, _, _):
                                let suffix = String(text.suffix(60)).replacingOccurrences(of: "\n", with: " ")
                                print("\r🤖 Codex: ... \(suffix)", terminator: "")
                            case .commandExecution(_, let command, _, _, _):
                                print("\r🛠️ Shell execution: \(command.prefix(60))...", terminator: "")
                            case .reasoning(_, let text, _, _):
                                let suffix = String(text.suffix(60)).replacingOccurrences(of: "\n", with: " ")
                                print("\r🧠 Thinking: ... \(suffix)", terminator: "")
                            default:
                                break
                            }
                            fflush(stdout)
                        }
                    }
                }
            }

            // Check if file todo.html was created
            let todoPath = "\(currentDir)/todo.html"
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

            await connectedCodex.close()
            codex = nil
            print("🔌 Connection closed gracefully.")

        } catch {
            await codex?.close()
            print("\n❌ Task execution failed with error: \(error)")
        }
    }
}
