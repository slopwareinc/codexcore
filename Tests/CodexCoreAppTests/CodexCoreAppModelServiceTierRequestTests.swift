import CodexCore
@testable import CodexCoreApp
@testable import CodexCoreUI
import XCTest

@MainActor
final class CodexCoreAppModelServiceTierRequestTests: XCTestCase {
    func testFollowUpBehaviorLoadsAndPersistsThroughAppModel() {
        let store = AppPreferenceStore()
        CodexFollowUpBehaviorStorage.save(.steer, to: store)

        let app = CodexCoreAppModel(
            clipboardService: CodexNoopClipboardService(),
            preferenceStore: store
        )

        XCTAssertEqual(app.followUpBehavior, .steer)
        app.followUpBehavior = .queue
        XCTAssertEqual(CodexFollowUpBehaviorStorage.load(from: store), .queue)
    }

    func testAppModelConstructorsCaptureTierAndMaximumEffort() throws {
        let (app, model, fast, _) = makeApp()
        app.configurationSession = CodexChatConfigurationSession(
            modelSelection: model,
            modelOptions: [model],
            serviceTierSelection: .tier(fast),
            reasoningSelection: .maximum
        )
        let preference = CodexModelPreference(
            model: model,
            serviceTier: .tier(fast),
            isServiceTierExplicit: true
        )
        app.lastManualModelPreference = preference
        app.modelPreferenceByThread["thread-1"] = preference

        let start = app.threadStartParameters()
        XCTAssertEqual(start.model, model.modelIdentifier)
        XCTAssertEqual(start.serviceTier, fast.id)

        app.isProjectlessDraft = false
        let resume = app.threadResumeParameters(threadID: "thread-1")
        let contextualResume = app.threadResumeParametersForCurrentContext(
            threadID: "thread-1"
        )
        XCTAssertEqual(resume.serviceTier, fast.id)
        XCTAssertEqual(contextualResume.serviceTier, fast.id)

        app.isProjectlessDraft = true
        app.projectlessDraftPaths = CodexProjectlessThreadPaths(
            workspaceRoot: "/tmp/projectless",
            cwd: "/tmp/projectless/work",
            outputDirectory: "/tmp/projectless/output"
        )
        let projectlessResume = app.threadResumeParametersForCurrentContext(
            threadID: "thread-1"
        )
        XCTAssertEqual(projectlessResume.cwd, "/tmp/projectless/work")
        XCTAssertEqual(projectlessResume.serviceTier, fast.id)

        let normalFork = app.threadForkParameters(threadID: "thread-1")
        let ephemeralFork = app.threadForkParameters(
            threadID: "thread-1",
            ephemeral: true
        )
        XCTAssertEqual(normalFork.serviceTier, fast.id)
        XCTAssertEqual(normalFork.ephemeral, false)
        XCTAssertEqual(ephemeralFork.serviceTier, fast.id)
        XCTAssertEqual(ephemeralFork.ephemeral, true)

        let turn = app.turnStartParameters(
            threadID: ThreadID("thread-1"),
            input: [.text("hello")],
            clientUserMessageID: "message-1"
        )
        XCTAssertEqual(turn.model, model.modelIdentifier)
        XCTAssertEqual(turn.serviceTier, fast.id)
        XCTAssertEqual(turn.effort?.rawValue, .string("max"))
        XCTAssertEqual(turn.multiAgentMode, CodexCoreAppModel.defaultMultiAgentMode)
    }

    func testNormalThreadStartsDoNotAdvertiseRealtimeVoiceTools() {
        let (app, model, _, _) = makeApp()
        app.configurationSession = CodexChatConfigurationSession(
            modelSelection: model,
            modelOptions: [model]
        )

        XCTAssertNil(app.threadStartParameters().dynamicTools)
        XCTAssertNil(app.voiceThreadStartParameters(
            wire: app.configurationSession.wireSelection,
            cwd: "/tmp",
            roots: ["/tmp"],
            developerInstructions: nil
        ).dynamicTools)
    }

    func testRealtimeVoiceToolsRequireSourceAndRealtimeStartKind() throws {
        let (app, model, _, _) = makeApp()
        app.configurationSession = CodexChatConfigurationSession(
            modelSelection: model,
            modelOptions: [model]
        )

        XCTAssertNil(CodexCoreAppModel.dynamicToolsForThreadStart(
            threadSource: "realtime_voice",
            threadStartKind: .normal
        ))
        XCTAssertNil(CodexCoreAppModel.dynamicToolsForThreadStart(
            threadSource: "cli",
            threadStartKind: .realtimeVoice
        ))

        let tools = try XCTUnwrap(CodexCoreAppModel.dynamicToolsForThreadStart(
            threadSource: "realtime_voice",
            threadStartKind: .realtimeVoice
        ))
        XCTAssertEqual(tools, CodexCoreAppModel.realtimeVoiceTaskToolSpecs)

        let start = try app.realtimeVoiceThreadStartParametersForCurrentDraft()
        XCTAssertEqual(start.threadSource, CodexSchemaThreadSource(.string("realtime_voice")))
        XCTAssertEqual(start.dynamicTools, tools)
    }

    func testVoiceConstructorsDropAmbientOverridesAndUseTargetThread() {
        let (app, model, fast, ultra) = makeApp()
        app.configurationSession = CodexChatConfigurationSession(
            modelSelection: model,
            modelOptions: [model],
            serviceTierSelection: .tier(fast),
            reasoningSelection: .maximum
        )

        let alternate = app.configurationSession.wireSelection.overriding(
            model: "alternate-model",
            effort: nil
        )
        let voiceStart = app.voiceThreadStartParameters(
            wire: alternate,
            cwd: "/tmp",
            roots: ["/tmp"],
            developerInstructions: nil
        )
        let voiceTurn = app.voiceTurnStartParameters(
            wire: alternate,
            cwd: "/tmp",
            roots: ["/tmp"],
            prompt: "hello",
            threadID: "new-thread",
            clientUserMessageID: "message-1"
        )
        XCTAssertEqual(voiceStart.model, "alternate-model")
        XCTAssertNil(voiceStart.serviceTier)
        XCTAssertEqual(voiceTurn.model, "alternate-model")
        XCTAssertNil(voiceTurn.serviceTier)
        XCTAssertNil(voiceTurn.effort)

        app.modelPreferenceByThread["target-thread"] = CodexModelPreference(
            model: model,
            serviceTier: .tier(ultra),
            isServiceTierExplicit: true
        )
        let resumeWire = app.taskWireSelection(
            for: "target-thread",
            explicitTierOnly: true
        )
        let targetWire = app.taskWireSelection(for: "target-thread")
            .omittingEffort()
        let targetResume = app.voiceThreadResumeParameters(
            wire: resumeWire,
            cwd: "/target",
            roots: ["/target"],
            threadID: "target-thread"
        )
        let targetTurn = app.voiceTurnStartParameters(
            wire: targetWire,
            cwd: "/target",
            roots: ["/target"],
            prompt: "continue",
            threadID: "target-thread",
            clientUserMessageID: "message-2"
        )
        XCTAssertEqual(targetResume.serviceTier, ultra.id)
        XCTAssertEqual(targetTurn.serviceTier, ultra.id)
        XCTAssertNil(targetTurn.effort)

        let sideTurn = app.turnStartParameters(
            threadID: ThreadID("target-thread"),
            input: [.text("side chat")],
            clientUserMessageID: "message-3",
            viewedThreadID: "viewed-thread"
        )
        XCTAssertEqual(sideTurn.model, model.modelIdentifier)
        XCTAssertEqual(sideTurn.serviceTier, ultra.id)
        XCTAssertNil(sideTurn.effort)
    }

    func testCollaborationModelOverrideDropsIncompatibleTierAndEffort() {
        let (app, model, fast, _) = makeApp()
        let plan = CodexCollaborationModeOption(
            name: "Plan",
            mode: "plan",
            modelIdentifier: "alternate-model",
            reasoning: .high
        )
        app.configurationSession = CodexChatConfigurationSession(
            collaborationModes: [plan],
            isPlanModeEnabled: true,
            modelSelection: model,
            modelOptions: [model],
            serviceTierSelection: .tier(fast),
            reasoningSelection: .maximum
        )
        app.modelPreferenceByThread["thread-1"] = CodexModelPreference(
            model: model,
            serviceTier: .tier(fast),
            isServiceTierExplicit: true
        )

        let turn = app.turnStartParameters(
            threadID: ThreadID("thread-1"),
            input: [.text("make a plan")],
            clientUserMessageID: "message-1"
        )

        XCTAssertEqual(turn.collaborationMode?.settings.model, "alternate-model")
        XCTAssertEqual(turn.model, model.modelIdentifier)
        XCTAssertNil(turn.serviceTier)
        XCTAssertNil(turn.effort)
    }

    func testForkServerNormalizationBecomesVisibleAfterActivation() {
        let (app, sourceModel, fast, ultra) = makeApp()
        let normalizedModel = CodexModelSelection(
            id: "normalized-model",
            displayName: "Normalized Model",
            modelIdentifier: "normalized-model",
            defaultReasoning: .maximum,
            supportedReasoning: [.maximum],
            serviceTiers: [ultra]
        )
        app.configurationSession = CodexChatConfigurationSession(
            modelSelection: sourceModel,
            modelOptions: [sourceModel, normalizedModel],
            serviceTierSelection: .tier(fast),
            reasoningSelection: .maximum
        )
        app.hydrateModelPreference(
            for: "fork-thread",
            modelID: normalizedModel.modelIdentifier,
            serviceTierID: ultra.id,
            provenance: CodexModelPreference(
                model: sourceModel,
                serviceTier: .tier(fast),
                isServiceTierExplicit: true
            )
        )

        // Production calls this immediately after activating the fork.
        app.applyPreferredModel(for: "fork-thread")

        XCTAssertEqual(
            app.configurationSession.modelSelection,
            normalizedModel
        )
        XCTAssertEqual(
            app.configurationSession.serviceTierSelection,
            .tier(ultra)
        )
    }

    func testVoiceDefaultTierProvenanceRemainsNonExplicit() {
        let (app, model, fast, _) = makeApp()
        let defaultFastModel = CodexModelSelection(
            id: model.id,
            displayName: model.displayName,
            modelIdentifier: model.modelIdentifier,
            defaultReasoning: model.defaultReasoning,
            supportedReasoning: model.supportedReasoning,
            serviceTiers: model.serviceTiers,
            defaultServiceTierID: fast.id
        )
        app.configurationSession = CodexChatConfigurationSession(
            modelSelection: defaultFastModel,
            modelOptions: [defaultFastModel],
            serviceTierSelection: .tier(fast),
            reasoningSelection: .maximum
        )
        app.lastManualModelPreference = CodexModelPreference(
            model: defaultFastModel,
            serviceTier: .tier(fast),
            isServiceTierExplicit: false
        )
        let wire = app.configurationSession.wireSelection
        let provenance = app.voiceThreadProvenance(for: wire)

        XCTAssertFalse(provenance.isServiceTierExplicit)
        app.hydrateModelPreference(
            for: "voice-thread",
            modelID: defaultFastModel.modelIdentifier,
            serviceTierID: fast.id,
            provenance: provenance
        )
        XCTAssertNil(
            app.taskWireSelection(
                for: "voice-thread",
                explicitTierOnly: true
            ).serviceTier
        )
    }

    func testUnavailableFastCommandHasNoPreferenceSideEffects() {
        let store = AppPreferenceStore()
        let (app, _, _, ultra) = makeApp(preferenceStore: store)
        let ultraOnly = CodexModelSelection(
            id: "ultra-only",
            displayName: "Ultra Only",
            modelIdentifier: "ultra-only",
            defaultReasoning: .maximum,
            supportedReasoning: [.maximum],
            serviceTiers: [ultra]
        )
        let preference = CodexModelPreference(
            model: ultraOnly,
            serviceTier: .tier(ultra),
            isServiceTierExplicit: false
        )
        app.configurationSession = CodexChatConfigurationSession(
            modelSelection: ultraOnly,
            modelOptions: [ultraOnly],
            serviceTierSelection: .tier(ultra),
            reasoningSelection: .maximum
        )
        app.lastManualModelPreference = preference
        let writesBeforeCommand = store.saveCount

        app.applyFastCommand()

        XCTAssertEqual(app.lastManualModelPreference, preference)
        XCTAssertEqual(
            app.configurationSession.serviceTierSelection,
            .tier(ultra)
        )
        XCTAssertEqual(store.saveCount, writesBeforeCommand)
    }

    func testFastCommandAndHydrationPreserveExplicitProvenance() {
        let (app, model, fast, _) = makeApp()
        app.configurationSession = CodexChatConfigurationSession(
            modelSelection: model,
            modelOptions: [model]
        )

        app.applyFastCommand()
        XCTAssertEqual(app.lastManualModelPreference?.serviceTierID, fast.id)
        XCTAssertEqual(
            app.lastManualModelPreference?.isServiceTierExplicit,
            true
        )

        let normalized = CodexModelSelection(
            id: "normalized",
            displayName: "Normalized",
            modelIdentifier: "normalized"
        )
        app.configurationSession = CodexChatConfigurationSession(
            modelSelection: normalized,
            modelOptions: [model, normalized]
        )
        app.hydrateModelPreference(
            for: "fork-thread",
            modelID: normalized.id,
            serviceTierID: nil,
            provenance: CodexModelPreference(
                model: model,
                serviceTier: .tier(fast),
                isServiceTierExplicit: true
            )
        )
        XCTAssertEqual(
            app.modelPreferenceByThread["fork-thread"],
            CodexModelPreference(
                model: normalized,
                serviceTier: .standard,
                isServiceTierExplicit: true,
                isAuthoritativeModelID: true
            )
        )

        app.hydrateModelPreference(
            for: "hidden-thread",
            modelID: "hidden-server-model",
            serviceTierID: nil
        )
        XCTAssertEqual(
            app.resolvedModelPreference(for: "hidden-thread")?.model.modelIdentifier,
            "hidden-server-model"
        )

        let explicitFast = CodexModelPreference(
            model: model,
            serviceTier: .tier(fast),
            isServiceTierExplicit: true
        )
        app.hydrateModelPreference(
            for: "fast-fork",
            modelID: model.modelIdentifier,
            serviceTierID: fast.id,
            provenance: explicitFast
        )
        XCTAssertEqual(
            app.taskWireSelection(
                for: "fast-fork",
                explicitTierOnly: true
            ).serviceTier,
            fast.id
        )
    }

    private func makeApp(
        preferenceStore: any CodexStringListPreferenceStore =
            CodexNoopStringListPreferenceStore()
    ) -> (
        CodexCoreAppModel,
        CodexModelSelection,
        CodexModelServiceTier,
        CodexModelServiceTier
    ) {
        let fast = CodexModelServiceTier(
            id: "priority",
            displayName: "Fast",
            detail: "1.5x speed"
        )
        let ultra = CodexModelServiceTier(
            id: "ultrafast",
            displayName: "UltraFast",
            detail: "Lowest latency"
        )
        let model = CodexModelSelection(
            id: "gpt-5.6-sol",
            displayName: "GPT-5.6 Sol",
            modelIdentifier: "gpt-5.6-sol",
            defaultReasoning: .maximum,
            supportedReasoning: [.maximum],
            serviceTiers: [fast, ultra]
        )
        return (
            CodexCoreAppModel(
                clipboardService: CodexNoopClipboardService(),
                preferenceStore: preferenceStore
            ),
            model,
            fast,
            ultra
        )
    }
}

private final class AppPreferenceStore:
    CodexStringListPreferenceStore,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [String: [String]] = [:]
    private(set) var saveCount = 0

    func loadStrings(forKey key: String) -> [String] {
        lock.withLock { values[key] ?? [] }
    }

    func saveStrings(_ strings: [String], forKey key: String) {
        lock.withLock {
            values[key] = strings
            saveCount += 1
        }
    }

    func hasStrings(forKey key: String) -> Bool {
        lock.withLock { values[key] != nil }
    }
}
