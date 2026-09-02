import XCTest
@testable import CodexCore
@testable import CodexCoreUI

final class CodexSessionStateTests: XCTestCase {
    private func account(
        type: String,
        email: String? = nil,
        planType: String = "unknown"
    ) -> CodexSchemaAccount {
        CodexSchemaAccount(.dictionary([
            "type": .string(type),
            "email": email.map(CodexJSONValue.string) ?? .null,
            "planType": .string(planType),
        ]))
    }

    func testAccountMenuSummaryPrefersTokenDisplayName() {
        let summary = CodexAccountMenuSummary(
            account: account(type: "chatgpt", email: "pranjal.paliwal@example.com", planType: "pro"),
            displayName: "Pranjal Paliwal",
            serverName: "Codex"
        )

        XCTAssertEqual(summary.displayName, "Pranjal Paliwal")
        XCTAssertEqual(summary.detail, "Pro")
        XCTAssertEqual(summary.initials, "PP")
    }

    func testAccountMenuSummaryFallsBackToEmailWhenTokenNameIsMissing() {
        let summary = CodexAccountMenuSummary(
            account: account(type: "chatgpt", email: "pranjal.paliwal@example.com", planType: "pro"),
            serverName: "Codex"
        )

        XCTAssertEqual(summary.displayName, "Pranjal Paliwal")
        XCTAssertEqual(summary.detail, "Pro")
        XCTAssertEqual(summary.initials, "PP")
    }

    func testAccountMenuSummaryFormatsUnavailableAccount() {
        let fallback = CodexAccountMenuSummary(account: nil, serverName: "Codex")
        XCTAssertEqual(fallback.displayName, "Codex")
        XCTAssertEqual(fallback.detail, "Available")
    }

    func testAccountMenuSummaryReadsCanonicalLiveAccountState() {
        let state = CanonicalAccountState(
            authMode: "chatgpt",
            planType: "pro",
            extensions: [
                "account": .dictionary([
                    "type": .string("chatgpt"),
                    "email": .string("pranjal.paliwal@example.com"),
                ]),
                "requiresOpenaiAuth": .bool(true),
            ]
        )

        let summary = CodexAccountMenuSummary(accountState: state, serverName: "Codex")

        XCTAssertEqual(summary.displayName, "Pranjal Paliwal")
        XCTAssertEqual(summary.detail, "Pro")
        XCTAssertEqual(summary.initials, "PP")
    }

    func testAuthSessionOwnsConnectionAuthenticationAndDeviceCodeState() {
        var session = CodexAuthSession()

        XCTAssertTrue(session.beginConnecting())
        XCTAssertFalse(session.beginConnecting())
        session.connectedAfterHandshake(server: "Codex")
        XCTAssertTrue(session.isConnected)
        XCTAssertEqual(session.serverName, "Codex")

        let signedIn = session.applyAccount(CodexSchemaGetAccountResponse(
            account: account(type: "chatgpt", email: "dev@example.com"),
            requiresOpenAIAuth: true
        ))
        XCTAssertTrue(signedIn.shouldContinue)
        XCTAssertEqual(signedIn.activity?.title, "Signed in")
        XCTAssertEqual(session.authLabel, "chatgpt · dev@example.com")
        XCTAssertTrue(session.isAuthenticated)

        let required = session.applyAccount(CodexSchemaGetAccountResponse(
            account: nil,
            requiresOpenAIAuth: true
        ))
        XCTAssertFalse(required.shouldContinue)
        XCTAssertEqual(required.activity?.title, "Authentication required")
        XCTAssertEqual(session.authLabel, "Sign-in required")
        XCTAssertFalse(session.isAuthenticated)

        let skipped = session.accountCheckSkipped(message: "offline")
        XCTAssertEqual(skipped.title, "Account check skipped")
        XCTAssertEqual(session.authLabel, "Account check skipped")

        let apiKey = session.apiKeyAccepted()
        XCTAssertEqual(apiKey.title, "API key accepted")
        XCTAssertEqual(session.authLabel, "OpenAI API key")
        XCTAssertTrue(session.isAuthenticated)

        let started = session.deviceCodeStarted(url: "https://example.com/device", code: "ABCD-EFGH")
        XCTAssertEqual(started.detail, "Code ABCD-EFGH")
        XCTAssertEqual(session.deviceCodeURL, "https://example.com/device")
        XCTAssertEqual(session.deviceCode, "ABCD-EFGH")

        let completed = session.deviceCodeCompleted()
        XCTAssertEqual(completed.title, "Signed in with ChatGPT")
        XCTAssertEqual(session.authLabel, "ChatGPT")
        XCTAssertNil(session.deviceCodeURL)
        XCTAssertNil(session.deviceCode)

        let failed = session.connectionFailed(message: "no server")
        XCTAssertEqual(failed.title, "Connection failed")
        XCTAssertEqual(session.connectionErrorMessage, "no server")

        session.resetAuthentication()
        XCTAssertEqual(session.authLabel, "Checking auth")
        XCTAssertTrue(session.isAuthenticated)
    }

    func testAuthSessionAppliesCanonicalLiveAccountAndLogout() {
        var session = CodexAuthSession()
        let signedIn = CanonicalAccountState(
            authMode: "chatgpt",
            planType: "pro",
            extensions: [
                "account": .dictionary([
                    "type": .string("chatgpt"),
                    "email": .string("dev@example.com"),
                ]),
                "requiresOpenaiAuth": .bool(true),
            ]
        )

        let result = session.applyCanonicalAccount(signedIn)
        XCTAssertTrue(result.shouldContinue)
        XCTAssertEqual(result.activity?.title, "Signed in")
        XCTAssertEqual(session.authLabel, "chatgpt · dev@example.com")
        XCTAssertTrue(session.isAuthenticated)
        XCTAssertNil(session.applyCanonicalAccount(signedIn).activity)

        let signedOut = CanonicalAccountState(extensions: [
            "account": .null,
            "requiresOpenaiAuth": .bool(true),
        ])
        let logout = session.applyCanonicalAccount(signedOut)
        XCTAssertFalse(logout.shouldContinue)
        XCTAssertEqual(logout.activity?.title, "Authentication required")
        XCTAssertEqual(session.authLabel, "Sign-in required")
        XCTAssertFalse(session.isAuthenticated)
    }

    func testComposerStateSessionScopesDraftByActiveThread() throws {
        var session = CodexComposerStateSession()

        session.setActiveThreadID("thread-a")
        session.draft = "Draft A"

        session.setActiveThreadID("thread-b")
        XCTAssertEqual(session.draft, "")
        session.draft = "Draft B"

        XCTAssertEqual(session.draft(for: "thread-a"), "Draft A")
        XCTAssertEqual(session.draft(for: "thread-b"), "Draft B")

        let submission = try XCTUnwrap(session.consumeDraftForTurn())
        XCTAssertEqual(submission.prompt, "Draft B")
        XCTAssertEqual(session.draft(for: "thread-b"), "")
        XCTAssertEqual(session.draft(for: "thread-a"), "Draft A")

        session.setActiveThreadID("thread-a")
        XCTAssertEqual(session.draft, "Draft A")
        session.clearDraft()
        XCTAssertEqual(session.draft(for: "thread-a"), "")
    }

    func testFileReferencesEncodeAndDecodeWithoutReadingContent() {
        let image = CodexReferencedFile(path: "/tmp/screenshot.png", kind: .image)
        let folder = CodexReferencedFile(path: "/tmp/project", kind: .directory)

        let encoded = CodexFileReferencePromptCodec.encode(
            files: [image, folder],
            request: "Please inspect these"
        )
        XCTAssertEqual(
            encoded,
            "\n# Files mentioned by the user:\n\n"
                + "## screenshot.png: /tmp/screenshot.png\n\n"
                + "## project: /tmp/project\n\n"
                + "## My request for Codex:\nPlease inspect these\n"
        )

        let decoded = CodexFileReferencePromptCodec.decode(encoded)
        XCTAssertEqual(decoded?.request, "Please inspect these")
        XCTAssertEqual(decoded?.files.map(\.path), [image.path, folder.path])
        XCTAssertEqual(decoded?.files.map(\.displayName), [image.displayName, folder.displayName])
        XCTAssertEqual(CodexFileReferencePromptCodec.visibleRequest(from: encoded), "Please inspect these")
        XCTAssertEqual(CodexFileReferencePromptCodec.visibleRequest(from: "ordinary text"), "ordinary text")
    }

    func testFileReferenceDecoderUsesEnvelopeDelimiterWhenRequestRepeatsHeader() throws {
        let file = CodexReferencedFile(path: "/tmp/reference.swift", kind: .file)
        let request = "Explain this heading:\n## My request for Codex:\nwithout treating it as metadata."

        let decoded = try XCTUnwrap(CodexFileReferencePromptCodec.decode(
            CodexFileReferencePromptCodec.encode(files: [file], request: request)
        ))

        XCTAssertEqual(decoded.request, request)
        XCTAssertEqual(decoded.files, [file])
    }

    func testDroppedURLClassificationAndRootFolderRoundTrip() throws {
        let temporaryFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-file-reference-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryFolder) }
        let imageURL = temporaryFolder.appendingPathComponent("preview.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: imageURL.path, contents: Data()))

        XCTAssertEqual(CodexReferencedFile.fromDroppedURL(temporaryFolder)?.kind, .directory)
        XCTAssertEqual(CodexReferencedFile.fromDroppedURL(imageURL)?.kind, .image)
        XCTAssertNil(CodexReferencedFile.fromDroppedURL(URL(string: "https://example.com/file")!))
        XCTAssertNil(CodexReferencedFile.fromDroppedURL(temporaryFolder.appendingPathComponent("missing.txt")))

        let root = CodexReferencedFile(path: "/", kind: .directory)
        XCTAssertFalse(root.displayName.isEmpty)
        let encoded = CodexFileReferencePromptCodec.encode(files: [root], request: "Inspect root")
        XCTAssertEqual(CodexFileReferencePromptCodec.decode(encoded)?.files.first?.path, "/")
    }

    func testFileDropBatchPreservesProviderOrderAndSkipsFailures() async {
        let first = URL(fileURLWithPath: "/tmp/first.txt")
        let third = URL(fileURLWithPath: "/tmp/third.txt")
        let received: [URL] = await withCheckedContinuation { continuation in
            let batch = CodexFileDropBatch(count: 3) { urls in
                continuation.resume(returning: urls)
            }
            batch.finish(index: 2, url: third)
            batch.finish(index: 0, url: first)
            batch.finish(index: 1, url: nil)
        }

        XCTAssertEqual(received, [first, third])
    }

    func testComposerFileReferencesAreScopedRemovableAndRetainedInSubmission() throws {
        let image = CodexReferencedFile(path: "/tmp/preview.png", kind: .image)
        let document = CodexReferencedFile(path: "/tmp/readme.md", kind: .file)
        var session = CodexComposerStateSession(activeThreadID: "thread-a")

        session.addReferencedFiles([image, document], for: "thread-a")
        session.setActiveThreadID("thread-b")
        XCTAssertTrue(session.referencedFiles.isEmpty)
        session.setActiveThreadID("thread-a")
        session.draft = "Summarize them"
        session.removeReferencedFile(id: image.id, for: "thread-a")

        let submission = try XCTUnwrap(session.consumeDraftForTurn())
        XCTAssertEqual(submission.referencedFiles, [document])
        XCTAssertEqual(submission.turnInput, [
            .text(CodexFileReferencePromptCodec.encode(files: [document], request: "Summarize them"))
        ])

        session.restore(submission)
        XCTAssertEqual(session.draft, "Summarize them")
        XCTAssertEqual(session.referencedFiles, [document])
    }

    func testComposerFileReferenceDeduplicationKeepsFirstOccurrenceOrder() {
        let first = CodexReferencedFile(path: "/tmp/readme.md", displayName: "first", kind: .file)
        let replacement = CodexReferencedFile(path: "/tmp/readme.md", displayName: "replacement", kind: .file)
        let second = CodexReferencedFile(path: "/tmp/notes.md", kind: .file)
        var session = CodexComposerStateSession(activeThreadID: "thread-a")

        session.setReferencedFiles([first, replacement, second], for: "thread-a")

        XCTAssertEqual(session.referencedFiles, [first, second])
    }

    func testClearingTransientThreadStatePreservesUnsentFileReferencesLikeDraftText() {
        let document = CodexReferencedFile(path: "/tmp/readme.md", kind: .file)
        var session = CodexComposerStateSession(draft: "Unsent", activeThreadID: nil)
        session.addReferencedFiles([document], for: nil)

        session.clearThreadState()

        XCTAssertEqual(session.draft, "Unsent")
        XCTAssertEqual(session.referencedFiles, [document])
    }

    func testFileOnlyFollowUpRetainsReferencesThroughQueueAndRetry() throws {
        let file = CodexReferencedFile(path: "/tmp/context.txt", kind: .file)
        var composer = CodexComposerStateSession(activeThreadID: "thread-a")
        composer.addReferencedFiles([file], for: "thread-a")

        let route = CodexTurnSubmissionSession.consumeDraft(
            composerSession: &composer,
            canSendFollowUp: true,
            isGoalPursuitEnabled: false
        )
        guard case .followUp(let submission) = route else {
            return XCTFail("Expected a file-only follow-up")
        }
        XCTAssertEqual(submission.prompt, "")
        XCTAssertEqual(submission.referencedFiles, [file])
        XCTAssertTrue(composer.referencedFiles.isEmpty)

        var mainChat = CodexMainChatSession()
        let prepared = CodexTurnSubmissionSession.prepareFollowUp(
            submission: submission,
            composerSession: &composer,
            mainChatSession: &mainChat,
            followUpBehavior: .queue,
            canSteer: true
        )
        guard case .queued(let queuedSubmission, _) = prepared else {
            return XCTFail("Expected queued follow-up")
        }
        XCTAssertEqual(queuedSubmission, submission)

        let dequeued = try XCTUnwrap(CodexTurnSubmissionSession.dequeueQueuedFollowUp(
            composerSession: &composer,
            mainChatSession: &mainChat,
            isSending: false
        ))
        XCTAssertEqual(dequeued.submission, submission)
        XCTAssertEqual(dequeued.input, submission.turnInput)

        _ = CodexTurnSubmissionSession.failQueuedFollowUp(
            dequeued,
            message: "offline",
            composerSession: &composer,
            mainChatSession: &mainChat
        )
        XCTAssertEqual(composer.dequeueQueuedFollowUpSubmission(isSending: false), submission)
    }

    func testComposerFollowUpQueueDrainsLargeFIFOWithoutChangingOrder() {
        var composer = CodexComposerStateSession(activeThreadID: "thread-a")
        for index in 0..<1_024 {
            composer.enqueueFollowUp(CodexComposerSubmission(
                prompt: "follow-up-\(index)",
                clientID: "client-\(index)",
                threadID: "thread-a"
            ))
        }

        for index in 0..<1_024 {
            XCTAssertEqual(
                composer.dequeueQueuedFollowUp(isSending: false),
                "follow-up-\(index)"
            )
        }
        XCTAssertTrue(composer.queuedFollowUps.isEmpty)
        XCTAssertNil(composer.dequeueQueuedFollowUp(isSending: false))
    }

    func testDurableQueuedSubmissionProjectsLosslesslyAndReplacesLocalQueue() throws {
        let encoded = CodexFileReferencePromptCodec.encode(
            files: [CodexReferencedFile(path: "/tmp/report.md", kind: .file)],
            request: "Summarize it"
        )
        let future = CodexJSONValue.dictionary([
            "type": .string("futureInput"),
            "opaque": .bool(true),
        ])
        let queued = CodexSchemaQueuedSubmission(
            clientUserMessageID: "client-1",
            id: "queue-1",
            input: [
                CodexSchemaUserInput(.dictionary([
                    "type": .string("text"),
                    "text": .string(encoded),
                ])),
                CodexSchemaUserInput(future),
            ]
        )
        let submission = CodexComposerSubmission(
            queuedSubmission: queued,
            threadID: "thread-a"
        )

        XCTAssertEqual(submission.queueID, "queue-1")
        XCTAssertEqual(submission.clientID, "client-1")
        XCTAssertEqual(submission.prompt, "Summarize it")
        XCTAssertEqual(submission.referencedFiles.map(\.path), ["/tmp/report.md"])
        XCTAssertEqual(submission.turnInput.last, .raw(future))

        var composer = CodexComposerStateSession(activeThreadID: "thread-a")
        composer.enqueueFollowUp("stale")
        composer.replaceQueuedFollowUps([submission], for: "thread-a")
        XCTAssertEqual(composer.queuedFollowUpSubmissions(for: "thread-a"), [submission])
        composer.replaceQueuedFollowUps([], for: "thread-a")
        XCTAssertTrue(composer.queuedFollowUpSubmissions(for: "thread-a").isEmpty)
    }

    func testQueuedAndFailedAttachmentSubmissionsStayWithOriginThread() throws {
        let file = CodexReferencedFile(path: "/tmp/thread-a.txt", kind: .file)
        var composer = CodexComposerStateSession(activeThreadID: "thread-a")
        composer.draft = "Use A"
        composer.addReferencedFiles([file], for: "thread-a")
        let submission = try XCTUnwrap(composer.consumeDraftForFollowUp())
        composer.enqueueFollowUp(submission)

        composer.setActiveThreadID("thread-b")
        composer.draft = "Draft B"
        XCTAssertTrue(composer.queuedFollowUps.isEmpty)
        XCTAssertNil(composer.dequeueQueuedFollowUpSubmission(isSending: false))

        composer.setActiveThreadID("thread-a")
        XCTAssertEqual(composer.dequeueQueuedFollowUpSubmission(isSending: false), submission)

        composer.setActiveThreadID("thread-b")
        composer.restore(submission)
        XCTAssertEqual(composer.draft(for: "thread-a"), "Use A")
        XCTAssertEqual(composer.referencedFiles(for: "thread-a"), [file])
        XCTAssertEqual(composer.draft(for: "thread-b"), "Draft B")
        XCTAssertTrue(composer.referencedFiles(for: "thread-b").isEmpty)
    }

    func testComposerStateSessionOwnsDraftSkillsMentionsAndFollowUps() throws {
        let skill = CodexSlashCommand(
            id: "skill:thermo",
            title: "Thermo Review",
            detail: "Strict review",
            systemImage: "hammer",
            section: "Skills",
            draftText: "Review this",
            skillName: "thermo-nuclear-code-quality-review",
            skillPath: "/skills/thermo/SKILL.md"
        )
        let mention = FuzzyFileSearchResult(
            fileName: "Store.swift",
            matchType: .file,
            path: "Sources/CodexCore/Store/Store.swift",
            root: "/repo",
            score: 0.9
        )

        var session = CodexComposerStateSession(draft: "  Inspect @Store.swift  ", sideChatDraft: "  side branch  ")
        session.attachSkill(skill)
        session.attachSkill(skill)
        XCTAssertEqual(session.attachedSkills, [skill])
        XCTAssertEqual(session.draft, "  Inspect @Store.swift  ")

        session.removeAttachedSkill(id: skill.id)
        XCTAssertEqual(session.attachedSkills, [])
        session.attachSkill(skill)

        session.draft = "  Inspect @Store.swift  "
        session.setMentionResults([mention])
        session.selectMention(mention)

        let submission = try XCTUnwrap(session.consumeDraftForTurn())
        XCTAssertEqual(submission.prompt, "Inspect @Store.swift")
        XCTAssertEqual(submission.skills, [skill])
        XCTAssertEqual(submission.mentions, [.mention(name: "Store.swift", path: "/repo/Sources/CodexCore/Store/Store.swift")])
        XCTAssertEqual(submission.turnInput, [
            .skill(name: "thermo-nuclear-code-quality-review", path: "/skills/thermo/SKILL.md"),
            .mention(name: "Store.swift", path: "/repo/Sources/CodexCore/Store/Store.swift"),
            .text("Inspect @Store.swift")
        ])
        XCTAssertEqual(session.draft, "")
        XCTAssertEqual(session.sideChatDraft, "  side branch  ")
        XCTAssertEqual(session.attachedSkills, [])
        XCTAssertEqual(session.mentionResults, [])

        XCTAssertEqual(session.trimmedSideChatDraft, "side branch")
        session.clearSideChatDraft()
        XCTAssertEqual(session.sideChatDraft, "")

        session.restore(submission)
        XCTAssertEqual(session.draft, "Inspect @Store.swift")
        XCTAssertEqual(session.attachedSkills, [skill])

        session.enqueueFollowUp("first")
        session.enqueueFollowUp("second")
        XCTAssertEqual(session.followUpHint(isSending: false, canSendFollowUp: false), "2 queued")
        session.followUpBehavior = .queue
        XCTAssertEqual(session.followUpHint(isSending: true, canSendFollowUp: true), "2 queued")
        let second = try XCTUnwrap(session.queuedFollowUpSubmissions(for: nil).last)
        XCTAssertEqual(session.takeQueuedFollowUpSubmission(clientID: second.clientID)?.prompt, "second")
        XCTAssertEqual(session.queuedFollowUps, ["first"])
        XCTAssertNil(session.dequeueQueuedFollowUp(isSending: true))
        XCTAssertEqual(session.dequeueQueuedFollowUp(isSending: false), "first")
        session.requeueFollowUp("retry")
        XCTAssertEqual(session.dequeueQueuedFollowUp(isSending: false), "retry")

        XCTAssertNil(CodexComposerStateSession(followUpBehavior: .queue).followUpHint(
            isSending: true,
            canSendFollowUp: true
        ))

        let skillRoute = session.routeSlashCommand(skill)
        XCTAssertEqual(skillRoute.activities.map(\.title), ["Skill attached"])
        XCTAssertEqual(skillRoute.activities.map(\.detail), ["Thermo Review"])
        XCTAssertEqual(skillRoute.hostActions, [])
        XCTAssertEqual(session.attachedSkills, [skill])
        XCTAssertEqual(session.draft, "Inspect @Store.swift")

        let sideRoute = session.routeSlashCommand(CodexSlashCommand(
            id: "side",
            title: "Side Chat",
            detail: "Open a side chat",
            systemImage: "sidebar.right"
        ))
        XCTAssertEqual(sideRoute.hostActions, [.openSideChat])
        XCTAssertEqual(session.draft, "Inspect @Store.swift")

        let mcpRoute = session.routeSlashCommand(CodexSlashCommand(
            id: "mcp",
            title: "MCP",
            detail: "Inspect configured MCP servers",
            systemImage: "server.rack"
        ))
        XCTAssertEqual(mcpRoute.hostActions, [.refreshMCPServers])

        session.draft = "/model"
        let modelRoute = session.routeSlashCommand(CodexSlashCommand(
            id: "model",
            title: "Model",
            detail: "Change model",
            systemImage: "sparkles"
        ))
        XCTAssertEqual(modelRoute.hostActions, [.openModelSelector])
        XCTAssertEqual(session.draft, "/model")

        session.draft = "/reasoning"
        let reasoningRoute = session.routeSlashCommand(CodexSlashCommand(
            id: "reasoning",
            title: "Reasoning",
            detail: "Change reasoning effort",
            systemImage: "brain"
        ))
        XCTAssertEqual(reasoningRoute.hostActions, [.openReasoningSelector])
        XCTAssertEqual(session.draft, "/reasoning")

        session.draft = "Keep this"
        let statusRoute = session.routeSlashCommand(CodexSlashCommand(
            id: "status",
            title: "Status",
            detail: "Show status",
            systemImage: "waveform.path.ecg"
        ))
        XCTAssertEqual(statusRoute.hostActions, [.presentStatus])
        XCTAssertEqual(session.draft, "Keep this")

        let goalRoute = session.routeSlashCommand(CodexSlashCommand(
            id: "goal",
            title: "Goal",
            detail: "Enable goal pursuit",
            systemImage: "target"
        ))
        XCTAssertEqual(goalRoute.hostActions, [.enableGoalPursuit])

        let planRoute = session.routeSlashCommand(CodexSlashCommand(
            id: "plan",
            title: "Plan mode",
            detail: "Enable plan mode",
            systemImage: "map"
        ))
        XCTAssertEqual(planRoute.hostActions, [.enablePlanMode])
    }

}
