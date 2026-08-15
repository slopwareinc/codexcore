import CodexCore
@testable import CodexCoreUI
import Foundation
import XCTest

final class CodexModelServiceTierTests: XCTestCase {
    func testCatalogParsingKeepsOneModelAndMaximumReasoning() {
        let response = CodexSchemaModelListResponse(data: [
            schemaModel(
                id: "gpt-5.6-sol",
                defaultTier: "priority",
                tiers: [
                    .init(description: "1.5x speed", id: "priority", name: "Fast"),
                    .init(description: "Lowest latency", id: "ultrafast", name: "UltraFast"),
                ],
                efforts: ["low", "max", "ultra"]
            ),
        ])

        let options = CodexModelSelection.options(from: response)

        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options[0].modelIdentifier, "gpt-5.6-sol")
        XCTAssertEqual(options[0].specialty, "coding")
        XCTAssertEqual(options[0].serviceTiers.map(\.id), ["priority", "ultrafast"])
        XCTAssertEqual(options[0].defaultServiceTierID, "priority")
        XCTAssertEqual(options[0].supportedReasoning, [.low, .maximum, .ultra])
        XCTAssertEqual(CodexReasoningSelection.maximum.effort, .max)
    }

    func testTierNormalizationDefaultsAndTransitions() throws {
        let fastA = tier("priority", "Fast A")
        let fastB = tier("priority", "Fast B")
        let ultra = tier("ultrafast", "UltraFast")
        let modelA = selection("a", tiers: [fastA, fastB])
        let modelB = selection("b", tiers: [fastB])
        let modelC = selection("c", defaultTier: "ultrafast", tiers: [ultra])
        let aliasDefault = selection("alias", defaultTier: "fast", tiers: [fastA])
        let invalidDefault = selection("d", defaultTier: "missing", tiers: [ultra])
        let noTiers = selection("e")

        XCTAssertEqual(modelA.serviceTiers, [fastA])
        XCTAssertEqual(modelC.defaultServiceTierSelection, .tier(ultra))
        XCTAssertEqual(aliasDefault.defaultServiceTierSelection, .tier(fastA))
        XCTAssertEqual(invalidDefault.defaultServiceTierSelection, .standard)
        XCTAssertEqual(modelA.serviceTierSelection(id: "fast"), .tier(fastA))
        XCTAssertEqual(modelA.serviceTierSelection(id: "default"), .standard)

        var session = CodexChatConfigurationSession(
            modelSelection: modelA,
            modelOptions: [modelA, modelB, modelC, noTiers]
        )
        XCTAssertTrue(session.selectServiceTier(.tier(fastA)))
        session.selectModel(modelB)
        XCTAssertEqual(session.serviceTierSelection, .tier(fastB))
        session.selectModel(modelC)
        XCTAssertEqual(session.serviceTierSelection, .tier(ultra))
        session.selectModel(noTiers)
        XCTAssertEqual(session.serviceTierSelection, .standard)
        XCTAssertNil(session.serviceTierSelection.protocolValue)

        let stale = tier("stale", "Stale")
        XCTAssertFalse(session.selectServiceTier(.tier(stale)))
        XCTAssertEqual(session.serviceTierSelection, .standard)
        XCTAssertEqual(
            CodexChatConfigurationSession(
                modelSelection: noTiers,
                modelOptions: [noTiers],
                serviceTierSelection: .tier(stale)
            ).serviceTierSelection,
            .standard
        )
    }

    func testProductionWireApplicatorCoversTaskAndVoicePaths() throws {
        let wire = CodexTaskWireSelection(
            modelIdentifier: "gpt-5.6-sol",
            serviceTier: "priority",
            effort: CodexSchemaReasoningEffort(.string("max"))
        )
        let start = wire.applying(to: CodexSchemaThreadStartParams(cwd: "/workspace"))
        let workspaceResume = wire.applying(to: CodexSchemaThreadResumeParams(
            cwd: "/workspace",
            threadID: "thread-1"
        ))
        let projectlessResume = wire.applying(to: CodexSchemaThreadResumeParams(
            cwd: "/tmp/projectless",
            threadID: "thread-1"
        ))
        let normalFork = wire.applying(to: CodexSchemaThreadForkParams(
            ephemeral: false,
            threadID: "thread-1"
        ))
        let ephemeralFork = wire.applying(to: CodexSchemaThreadForkParams(
            ephemeral: true,
            threadID: "thread-1"
        ))
        let turn = wire.applying(to: CodexSchemaTurnStartParams(
            input: [],
            threadID: "thread-1"
        ))

        for request in [
            try encodedObject(start),
            try encodedObject(workspaceResume),
            try encodedObject(projectlessResume),
            try encodedObject(normalFork),
            try encodedObject(ephemeralFork),
            try encodedObject(turn),
        ] {
            XCTAssertEqual(request["model"], .string("gpt-5.6-sol"))
            XCTAssertEqual(request["serviceTier"], .string("priority"))
        }
        XCTAssertEqual(turn.effort?.rawValue, .string("max"))
        XCTAssertEqual(workspaceResume.cwd, "/workspace")
        XCTAssertEqual(projectlessResume.cwd, "/tmp/projectless")
        XCTAssertEqual(normalFork.ephemeral, false)
        XCTAssertEqual(ephemeralFork.ephemeral, true)

        let alternateVoice = wire.overriding(model: "other-model", effort: "high")
        let voiceStart = alternateVoice.applying(to: CodexSchemaThreadStartParams())
        let voiceTurn = alternateVoice.applying(to: CodexSchemaTurnStartParams(
            input: [],
            threadID: "voice-thread"
        ))
        XCTAssertEqual(voiceStart.model, "other-model")
        XCTAssertNil(voiceStart.serviceTier)
        XCTAssertEqual(voiceTurn.model, "other-model")
        XCTAssertNil(voiceTurn.serviceTier)
        XCTAssertEqual(voiceTurn.effort?.rawValue, .string("high"))

        let modelOnlyVoice = wire.overriding(
            model: "other-model",
            effort: nil
        ).applying(to: CodexSchemaTurnStartParams(
            input: [],
            threadID: "voice-thread"
        ))
        XCTAssertNil(modelOnlyVoice.serviceTier)
        XCTAssertNil(modelOnlyVoice.effort)

        let standard = CodexTaskWireSelection(
            modelIdentifier: "gpt-5.6-sol",
            serviceTier: nil,
            effort: wire.effort
        )
        XCTAssertNil(try encodedObject(
            standard.applying(to: CodexSchemaTurnStartParams(
                input: [],
                threadID: "thread-1"
            ))
        )["serviceTier"])
    }

    func testTargetThreadWireNeverInheritsAmbientFastTier() {
        let fast = tier("priority", "Fast")
        let ultra = tier("ultrafast", "UltraFast")
        let model = selection("gpt-5.6-sol", tiers: [fast, ultra])
        var session = CodexChatConfigurationSession(
            modelSelection: model,
            modelOptions: [model],
            reasoningSelection: .maximum
        )
        XCTAssertTrue(session.selectServiceTier(.tier(fast)))
        XCTAssertEqual(session.wireSelection.serviceTier, "priority")

        let resumedStandard = session.resolveModelPreference(CodexModelPreference(
            modelID: model.id,
            serviceTierID: nil,
            isServiceTierExplicit: false
        ))
        let standardResume = session.wireSelection(
            for: resumedStandard,
            explicitTierOnly: true
        )
        let standardTurn = session.wireSelection(for: resumedStandard)
        XCTAssertNil(standardResume.applying(to: CodexSchemaThreadResumeParams(
            threadID: "thread-b"
        )).serviceTier)
        XCTAssertNil(standardTurn.applying(to: CodexSchemaTurnStartParams(
            input: [],
            threadID: "thread-b"
        )).serviceTier)

        let targetUltra = session.resolveModelPreference(CodexModelPreference(
            modelID: model.id,
            serviceTierID: ultra.id,
            isServiceTierExplicit: true
        ))
        let targetResume = session.wireSelection(
            for: targetUltra,
            explicitTierOnly: true
        ).applying(to: CodexSchemaThreadResumeParams(threadID: "thread-c"))
        let targetTurn = session.wireSelection(for: targetUltra).applying(
            to: CodexSchemaTurnStartParams(input: [], threadID: "thread-c")
        )
        let backgroundTurn = session.wireSelection(for: targetUltra)
            .omittingEffort()
            .applying(to: CodexSchemaTurnStartParams(
                input: [],
                threadID: "thread-c"
            ))
        XCTAssertEqual(targetResume.serviceTier, "ultrafast")
        XCTAssertEqual(targetTurn.serviceTier, "ultrafast")
        XCTAssertNil(backgroundTurn.effort)
    }

    func testCatalogCacheClearsOnEmptyAndFailureAndExactIDWinsAliases() {
        let alias = selection("alias")
        let exact = CodexModelSelection(
            id: "wire-shared",
            displayName: "Exact",
            modelIdentifier: "exact-wire"
        )
        let aliasOwner = CodexModelSelection(
            id: "alias-owner",
            displayName: "Alias Owner",
            modelIdentifier: "wire-shared"
        )
        var session = CodexChatConfigurationSession(
            modelSelection: alias,
            modelOptions: [alias]
        )
        session.applyModelResponse(CodexSchemaModelListResponse(data: [
            schemaModel(id: aliasOwner.id, model: "wire-shared", efforts: ["medium"]),
            schemaModel(id: exact.id, model: "exact-wire", efforts: ["medium"]),
        ]))

        let preference = CodexModelPreference(
            modelID: "wire-shared",
            serviceTierID: nil,
            isServiceTierExplicit: false
        )
        XCTAssertEqual(session.resolveModelPreference(preference).model.id, exact.id)

        session.applyModelResponse(CodexSchemaModelListResponse(data: []))
        XCTAssertEqual(
            session.resolveModelPreference(preference).model,
            .appServerDefault
        )

        session.applyModelResponse(CodexSchemaModelListResponse(data: [
            schemaModel(id: exact.id, model: "exact-wire", efforts: ["medium"]),
        ]))
        session.failModelRefresh(message: "offline")
        XCTAssertEqual(
            session.resolveModelPreference(preference).model,
            .appServerDefault
        )
    }

    func testPersistenceMigratesLegacySpeedSafelyAndRoundTripsPerThread() {
        let store = ModelPreferenceStore()
        CodexModelPreferenceStorage.saveLastModelID(
            "gpt-5.6-sol-speed",
            to: store
        )
        let migrated = CodexModelPreferenceStorage.loadLastSelection(from: store)
        XCTAssertEqual(migrated?.modelID, "gpt-5.6-sol")
        XCTAssertEqual(migrated?.serviceTierID, "fast")
        XCTAssertEqual(migrated?.isServiceTierExplicit, true)

        let fast = tier("priority", "Fast")
        let fastModel = selection("gpt-5.6-sol", tiers: [fast])
        let standardModel = selection("gpt-5.6-sol")
        let fastSession = CodexChatConfigurationSession(
            modelSelection: fastModel,
            modelOptions: [fastModel]
        )
        let standardSession = CodexChatConfigurationSession(
            modelSelection: standardModel,
            modelOptions: [standardModel]
        )
        XCTAssertEqual(
            migrated.map(fastSession.resolveModelPreference)?.serviceTier,
            .tier(fast)
        )
        XCTAssertEqual(
            migrated.map(standardSession.resolveModelPreference)?.serviceTier,
            .standard
        )

        CodexModelPreferenceStorage.saveThreadModelIDs(
            ["thread-b": fastModel.id],
            to: store
        )
        XCTAssertEqual(
            CodexModelPreferenceStorage.loadThreadSelections(from: store)["thread-b"],
            CodexModelPreference(
                modelID: fastModel.id,
                serviceTierID: nil,
                isServiceTierExplicit: false
            )
        )

        let normal = CodexModelPreference(
            modelID: fastModel.id,
            serviceTierID: nil,
            isServiceTierExplicit: false
        )
        let defaultFastModel = selection(
            fastModel.id,
            defaultTier: fast.id,
            tiers: [fast]
        )
        let defaultFastSession = CodexChatConfigurationSession(
            modelSelection: defaultFastModel,
            modelOptions: [defaultFastModel]
        )
        XCTAssertEqual(
            defaultFastSession.resolveModelPreference(normal).serviceTier,
            .tier(fast)
        )
        XCTAssertEqual(
            defaultFastSession.resolveModelPreference(CodexModelPreference(
                model: defaultFastModel,
                serviceTier: .standard,
                isServiceTierExplicit: true
            )).serviceTier,
            .standard
        )
        let perThread = ["thread-a": migrated!, "thread-b": normal]
        CodexModelPreferenceStorage.saveLastSelection(normal, to: store)
        CodexModelPreferenceStorage.saveThreadSelections(perThread, to: store)
        XCTAssertEqual(CodexModelPreferenceStorage.loadLastSelection(from: store), normal)
        XCTAssertEqual(CodexModelPreferenceStorage.loadThreadSelections(from: store), perThread)
    }

    private func encodedObject<Value: Encodable>(
        _ value: Value
    ) throws -> [String: CodexJSONValue] {
        guard case .dictionary(let object) = try CodexJSONValue(encoding: value) else {
            throw NSError(domain: "CodexModelServiceTierTests", code: 1)
        }
        return object
    }

    private func tier(_ id: String, _ name: String) -> CodexModelServiceTier {
        CodexModelServiceTier(id: id, displayName: name, detail: "\(name) detail")
    }

    private func selection(
        _ id: String,
        defaultTier: String? = nil,
        tiers: [CodexModelServiceTier] = []
    ) -> CodexModelSelection {
        CodexModelSelection(
            id: id,
            displayName: id,
            modelIdentifier: id,
            defaultReasoning: .maximum,
            supportedReasoning: [.maximum, .ultra],
            serviceTiers: tiers,
            defaultServiceTierID: defaultTier
        )
    }

    private func schemaModel(
        id: String,
        model: String? = nil,
        defaultTier: String? = nil,
        tiers: [CodexSchemaModelServiceTier] = [],
        efforts: [String]
    ) -> CodexSchemaModel {
        CodexSchemaModel(
            additionalSpeedTiers: ["fast"],
            defaultReasoningEffort: CodexSchemaReasoningEffort(.string(efforts[0])),
            defaultServiceTier: defaultTier,
            description: "\(id) description",
            displayName: id,
            hidden: false,
            id: id,
            isDefault: true,
            model: model ?? id,
            modelSpecialty: "coding",
            serviceTiers: tiers,
            supportedReasoningEfforts: efforts.map {
                CodexSchemaReasoningEffortOption(
                    description: "\($0) reasoning",
                    reasoningEffort: CodexSchemaReasoningEffort(.string($0))
                )
            }
        )
    }
}

private final class ModelPreferenceStore:
    CodexStringListPreferenceStore,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [String: [String]] = [:]

    func loadStrings(forKey key: String) -> [String] {
        lock.withLock { values[key] ?? [] }
    }

    func saveStrings(_ strings: [String], forKey key: String) {
        lock.withLock { values[key] = strings }
    }

    func hasStrings(forKey key: String) -> Bool {
        lock.withLock { values[key] != nil }
    }
}
