import AppKit
import CodexCore
import Foundation
import Testing
import XCTest
@testable import CodexCoreApp

@Suite("Native Voice overlay policy")
struct CodexVoiceOverlayTests {
    @Test("Handoff completion is sequence guarded and idempotent")
    func handoffIsExactlyOnce() {
        var machine = CodexVoicePresentationStateMachine()
        machine.reduce(.launch(threadID: "voice-thread", surface: .mainThread))
        machine.reduce(.session(phase: .listening, threadID: "voice-thread", surface: .mainThread))
        machine.reduce(.setMicrophoneMuted(true))
        machine.reduce(.setOutputMuted(true))

        machine.reduce(.handoff(to: .globalOverlay))
        guard case let .handingOff(from, to, sequence) = machine.state.phase else {
            Issue.record("expected an explicit handoff phase")
            return
        }
        #expect(from == .mainThread)
        #expect(to == .globalOverlay)
        #expect(machine.state.conversationID == "voice-thread")

        machine.reduce(.completeHandoff(sequence: sequence + 1))
        #expect(machine.state.surface == .mainThread)
        #expect(machine.state.handoff?.sequence == sequence)

        machine.reduce(.completeHandoff(sequence: sequence))
        #expect(machine.state.surface == .globalOverlay)
        #expect(machine.state.phase == .listening)
        #expect(machine.state.handoff == nil)
        #expect(machine.state.conversationID == "voice-thread")
        #expect(machine.state.microphoneMuted)
        #expect(machine.state.outputMuted)

        // A duplicate completion cannot create a second transition.
        machine.reduce(.completeHandoff(sequence: sequence))
        #expect(machine.state.surface == .globalOverlay)
        #expect(machine.state.phase == .listening)
    }

    @Test("State machine retains the transport identity across retry and stop")
    func retryAndStopRetainThenReleaseIdentity() {
        var machine = CodexVoicePresentationStateMachine()
        machine.reduce(.launch(threadID: "voice-thread", surface: .globalOverlay))
        machine.reduce(.session(
            phase: .failed("Microphone access is required for Voice chat."),
            threadID: "voice-thread",
            surface: .globalOverlay
        ))
        #expect(machine.state.conversationID == "voice-thread")
        #expect(machine.state.phase == .retryableFailure("Microphone access is required for Voice chat."))

        machine.reduce(.session(phase: .starting, threadID: "voice-thread", surface: .globalOverlay))
        #expect(machine.state.conversationID == "voice-thread")
        #expect(machine.state.phase == .launching)
        machine.reduce(.stop)
        #expect(machine.state.phase == .stopped)
        #expect(machine.state.conversationID == nil)
    }

    @Test("Bounds restore by display, resolution, then normalized migration")
    func boundsMigration() {
        let source = CodexVoiceOverlayDisplay(
            identifier: 1,
            bounds: CGRect(x: 0, y: 0, width: 2_000, height: 1_200),
            workArea: CGRect(x: 0, y: 0, width: 2_000, height: 1_160)
        )
        let target = CodexVoiceOverlayDisplay(
            identifier: 2,
            bounds: CGRect(x: 2_000, y: 0, width: 1_600, height: 1_000),
            workArea: CGRect(x: 2_000, y: 0, width: 1_600, height: 960)
        )
        var store = CodexVoiceOverlayBoundsStore()
        store.remember(frame: CGRect(x: 1_000, y: 500, width: 360, height: 176), on: source)

        let migrated = store.restoredFrame(on: target)
        #expect(migrated.width == 360)
        #expect(migrated.height >= 176)
        #expect(migrated.minX >= target.workArea.minX + 24)
        #expect(migrated.maxX <= target.workArea.maxX - 24)
        #expect(migrated.minY >= target.workArea.minY + 24)
        #expect(migrated.maxY <= target.workArea.maxY - 24)

        let exact = store.restoredFrame(on: source)
        #expect(exact == CGRect(x: 1_000, y: 500, width: 360, height: 176).integral)
    }

    @Test("Bounds clamp oversized saved frames into the work area")
    func boundsClamp() {
        let display = CodexVoiceOverlayDisplay(
            identifier: 4,
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            workArea: CGRect(x: 0, y: 0, width: 800, height: 560)
        )
        var store = CodexVoiceOverlayBoundsStore()
        store.remember(frame: CGRect(x: -500, y: -500, width: 2_000, height: 2_000), on: display)
        let restored = store.restoredFrame(on: display)
        #expect(restored.minX >= 24)
        #expect(restored.minY >= 24)
        #expect(restored.maxX <= 776)
        #expect(restored.maxY <= 536)
    }

    @Test("Native panel policy is floating, all-spaces, and passive by default")
    @MainActor
    func appKitPanelPolicy() throws {
        guard !NSScreen.screens.isEmpty else {
            throw XCTSkip("Skipped: AppKit integration requires a live desktop display")
        }
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 176),
            styleMask: CodexVoiceOverlayWindowPolicy.styleMask,
            backing: .buffered,
            defer: true
        )
        CodexVoiceOverlayWindowPolicy.configure(panel)
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.ignoresMouseEvents)
        #expect(!panel.isOpaque)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        panel.close()
    }

    @Test("Voice telemetry strips transcript, protocol, and payload fields")
    @MainActor
    func voiceTelemetryIsMetadataOnly() {
        let safe = CodexVoiceLog.sanitizedFields([
            "transcript": "private words",
            "response": "wire response",
            "item": "audio or transcript item",
            "sdp": "candidate data",
            "displayID": "42",
            "phase": "listening",
        ])
        #expect(safe == ["displayID": "42", "phase": "listening"])
    }

    @Test("Voice advertises the explicit end-call dynamic tool")
    @MainActor
    func endCallToolMatchesOfficialContract() {
        for spec in CodexCoreAppModel.voiceTaskToolSpecs {
            guard case let .dictionary(object) = spec.rawValue,
                  object["type"] == .string("function"),
                  let nameValue = object["name"],
                  case let .string(name) = nameValue
            else { continue }
            guard name == "end_realtime_voice_call" else { continue }
            guard let descriptionValue = object["description"],
                  case let .string(description) = descriptionValue,
                  let schemaValue = object["inputSchema"],
                  case let .dictionary(schema) = schemaValue,
                  let propertiesValue = schema["properties"],
                  case let .dictionary(properties) = propertiesValue,
                  let requiredValue = schema["required"],
                  case let .array(required) = requiredValue
            else {
                Issue.record("end-call tool did not have the expected object schema")
                return
            }
            #expect(description.contains("Only call this tool if the user explicitly asks"))
            #expect(properties.isEmpty)
            #expect(required.isEmpty)
            return
        }
        Issue.record("end-call tool was not advertised")
    }
}
