import AppKit
import Foundation
import SwiftUI
import Observation

/// The two surfaces that can present one Voice session. The transport and
/// transcript are deliberately not part of this value: a handoff only changes
/// where the existing session is rendered.
enum CodexVoicePresentationSurface: String, Codable, Sendable {
    case mainThread = "main-thread"
    case globalOverlay = "global-overlay"
}

enum CodexVoicePresentationPhase: Equatable, Codable, Sendable {
    case inactive
    case launching
    case connected
    case listening
    case thinking
    case speaking
    case handingOff(from: CodexVoicePresentationSurface, to: CodexVoicePresentationSurface, sequence: UInt64)
    case retryableFailure(String)
    case hidden
    case stopped
}

struct CodexVoicePresentationHandoff: Equatable, Codable, Sendable {
    let from: CodexVoicePresentationSurface
    let to: CodexVoicePresentationSurface
    let sequence: UInt64
}

struct CodexVoicePresentationState: Equatable, Codable, Sendable {
    var conversationID: String?
    var hostID: String
    var surface: CodexVoicePresentationSurface
    var phase: CodexVoicePresentationPhase
    var handoff: CodexVoicePresentationHandoff?
    var captionsVisible: Bool
    var activityVisible: Bool
    var microphoneMuted: Bool
    var outputMuted: Bool

    static let inactive = CodexVoicePresentationState(
        conversationID: nil,
        hostID: "local",
        surface: .mainThread,
        phase: .inactive,
        handoff: nil,
        captionsVisible: true,
        activityVisible: true,
        microphoneMuted: false,
        outputMuted: false
    )
}

enum CodexVoicePresentationEvent: Equatable, Sendable {
    case launch(threadID: String, surface: CodexVoicePresentationSurface)
    case session(phase: CodexVoiceChatSession.Phase, threadID: String?, surface: CodexVoicePresentationSurface)
    case handoff(to: CodexVoicePresentationSurface)
    case completeHandoff(sequence: UInt64)
    case retry(String)
    case hide
    case stop
    case toggleCaptions
    case toggleActivity
    case setMicrophoneMuted(Bool)
    case setOutputMuted(Bool)
}

/// Small, deterministic state machine used by the AppKit owner and unit tests.
/// Handoff completion is sequence guarded, so a delayed completion from an old
/// surface cannot move a newer presentation back or duplicate a session.
struct CodexVoicePresentationStateMachine: Sendable {
    private(set) var state = CodexVoicePresentationState.inactive
    private var nextHandoffSequence: UInt64 = 0
    private var phaseBeforeHandoff: CodexVoicePresentationPhase?

    mutating func reduce(_ event: CodexVoicePresentationEvent) {
        switch event {
        case let .launch(threadID, surface):
            state.conversationID = threadID
            state.surface = surface
            state.phase = .launching
            state.handoff = nil
        case let .session(phase, threadID, surface):
            if let threadID { state.conversationID = threadID }
            state.surface = surface
            state.handoff = nil
            switch phase {
            case .inactive: state.phase = .inactive
            case .starting: state.phase = .launching
            case .listening: state.phase = .listening
            case .thinking: state.phase = .thinking
            case .speaking: state.phase = .speaking
            case let .failed(message): state.phase = .retryableFailure(message)
            }
        case let .handoff(to):
            guard state.surface != to else { return }
            nextHandoffSequence &+= 1
            phaseBeforeHandoff = state.phase
            let handoff = CodexVoicePresentationHandoff(
                from: state.surface,
                to: to,
                sequence: nextHandoffSequence
            )
            state.handoff = handoff
            state.phase = .handingOff(from: handoff.from, to: handoff.to, sequence: handoff.sequence)
        case let .completeHandoff(sequence):
            guard case let .handingOff(_, to, activeSequence) = state.phase,
                  activeSequence == sequence,
                  state.handoff?.sequence == sequence
            else { return }
            state.surface = to
            state.handoff = nil
            state.phase = switch phaseBeforeHandoff {
            case .none, .some(.launching), .some(.connected): .connected
            case let .some(phase): phase
            }
            phaseBeforeHandoff = nil
        case let .retry(message):
            state.phase = .retryableFailure(message)
        case .hide:
            guard state.phase != .inactive, state.phase != .stopped else { return }
            state.phase = .hidden
        case .stop:
            state.phase = .stopped
            state.conversationID = nil
            state.handoff = nil
        case .toggleCaptions:
            state.captionsVisible.toggle()
        case .toggleActivity:
            state.activityVisible.toggle()
        case let .setMicrophoneMuted(value):
            state.microphoneMuted = value
        case let .setOutputMuted(value):
            state.outputMuted = value
        }
    }
}

struct CodexVoiceOverlayDisplay: Equatable, Codable, Sendable {
    let identifier: UInt32
    let bounds: CGRect
    let workArea: CGRect

    init(identifier: UInt32, bounds: CGRect, workArea: CGRect) {
        self.identifier = identifier
        self.bounds = bounds
        self.workArea = workArea
    }

    var resolutionKey: String {
        "\(Int(bounds.width))x\(Int(bounds.height))"
    }
}

struct CodexVoiceOverlayPersistedBounds: Equatable, Codable, Sendable {
    var frame: CGRect
    var display: CodexVoiceOverlayDisplay
}

/// Display-aware bounds persistence. The migration path intentionally stores
/// both display ID and resolution, then falls back to normalized coordinates
/// when a monitor is replaced or its stable ID changes.
struct CodexVoiceOverlayBoundsStore: Sendable {
    private(set) var byDisplayID: [String: CodexVoiceOverlayPersistedBounds]
    private(set) var byResolution: [String: CodexVoiceOverlayPersistedBounds]

    init(
        byDisplayID: [String: CodexVoiceOverlayPersistedBounds] = [:],
        byResolution: [String: CodexVoiceOverlayPersistedBounds] = [:]
    ) {
        self.byDisplayID = byDisplayID
        self.byResolution = byResolution
    }

    mutating func remember(frame: CGRect, on display: CodexVoiceOverlayDisplay) {
        let entry = CodexVoiceOverlayPersistedBounds(frame: frame, display: display)
        byDisplayID[String(display.identifier)] = entry
        byResolution[display.resolutionKey] = entry
    }

    func restoredFrame(
        on display: CodexVoiceOverlayDisplay,
        defaultSize: CGSize = CGSize(width: 360, height: 176),
        margin: CGFloat = 24
    ) -> CGRect {
        let saved = byDisplayID[String(display.identifier)] ?? byResolution[display.resolutionKey]
        let candidate: CGRect
        if let saved {
            candidate = saved.frame
        } else if let saved = byDisplayID.values.first ?? byResolution.values.first {
            let source = saved.display.bounds
            let xRatio = source.width > 0 ? (saved.frame.minX - source.minX) / source.width : 1
            let yRatio = source.height > 0 ? (saved.frame.minY - source.minY) / source.height : 0
            candidate = CGRect(
                x: display.bounds.minX + xRatio * display.bounds.width,
                y: display.bounds.minY + yRatio * display.bounds.height,
                width: saved.frame.width,
                height: saved.frame.height
            )
        } else {
            candidate = CGRect(
                x: display.workArea.maxX - defaultSize.width - margin,
                y: display.workArea.minY + margin,
                width: defaultSize.width,
                height: defaultSize.height
            )
        }
        return Self.clamp(candidate, to: display.workArea, margin: margin)
    }

    mutating func restoreAndRemember(
        on display: CodexVoiceOverlayDisplay,
        defaultSize: CGSize = CGSize(width: 360, height: 176),
        margin: CGFloat = 24
    ) -> CGRect {
        let frame = restoredFrame(on: display, defaultSize: defaultSize, margin: margin)
        remember(frame: frame, on: display)
        return frame
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(Storage(byDisplayID: byDisplayID, byResolution: byResolution))
    }

    static func decoded(_ data: Data?) -> Self {
        guard let data,
              let storage = try? JSONDecoder().decode(Storage.self, from: data)
        else { return Self() }
        return Self(byDisplayID: storage.byDisplayID, byResolution: storage.byResolution)
    }

    private struct Storage: Codable, Sendable {
        let byDisplayID: [String: CodexVoiceOverlayPersistedBounds]
        let byResolution: [String: CodexVoiceOverlayPersistedBounds]
    }

    private static func clamp(_ frame: CGRect, to workArea: CGRect, margin: CGFloat) -> CGRect {
        var result = frame
        result.size.width = min(max(220, result.width), max(220, workArea.width - margin * 2))
        result.size.height = min(max(132, result.height), max(132, workArea.height - margin * 2))
        result.origin.x = min(
            max(result.origin.x, workArea.minX + margin),
            workArea.maxX - result.width - margin
        )
        result.origin.y = min(
            max(result.origin.y, workArea.minY + margin),
            workArea.maxY - result.height - margin
        )
        return result.integral
    }
}

private final class CodexVoiceOverlayPanel: NSPanel {
    var keyboardInteractionEnabled = false
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { keyboardInteractionEnabled }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

@MainActor
enum CodexVoiceOverlayWindowPolicy {
    static let styleMask: NSWindow.StyleMask = [.borderless, .resizable, .nonactivatingPanel]
    static let collectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
        .ignoresCycle,
        .stationary,
    ]

    static func configure(_ panel: NSPanel) {
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = collectionBehavior
        panel.isExcludedFromWindowsMenu = true
        panel.ignoresMouseEvents = true
    }
}

@MainActor
final class CodexVoiceOverlayWindowController: NSObject, NSWindowDelegate {
    static let boundsDefaultsKey = "CodexCore.VoiceOverlay.Bounds.v1"
    static let openDefaultsKey = "CodexCore.VoiceOverlay.Open.v1"
    static let hostID = "local"

    private let model: CodexCoreAppModel
    private let mainThreadVisibilityProvider: @MainActor () -> Bool
    private var panel: CodexVoiceOverlayPanel?
    private var boundsStore: CodexVoiceOverlayBoundsStore
    private var stateMachine = CodexVoicePresentationStateMachine()
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var pointerOffTimer: Timer?
    private var keyboardOffTimer: Timer?
    private var isMainThreadVisible = false
    private var hasRestoredInitialFrame = false
    private var isDisposed = false

    var onRestoreMainWindow: (@MainActor (_ focusComposer: Bool) -> Void)?

    var state: CodexVoicePresentationState { stateMachine.state }
    var isActive: Bool { model.voiceSession.isActive || model.voiceSession.phase != .inactive }

    init(
        model: CodexCoreAppModel,
        mainThreadVisibilityProvider: @escaping @MainActor () -> Bool = { false }
    ) {
        self.model = model
        self.mainThreadVisibilityProvider = mainThreadVisibilityProvider
        self.boundsStore = CodexVoiceOverlayBoundsStore.decoded(
            UserDefaults.standard.data(forKey: Self.boundsDefaultsKey)
        )
        super.init()
        model.voiceSession.onPhaseChanged = { [weak self] phase in
            self?.sessionPhaseChanged(phase)
        }
        model.onVoicePresentationContextChanged = { [weak self] in
            self?.isMainThreadVisible = self?.mainThreadVisibilityProvider() ?? false
            self?.reconcilePresentationContext()
        }
    }

    func start() {
        guard !isDisposed else { return }
        installLifecycleObservers()
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        ) { [weak self] event in
            Task { @MainActor [weak self] in self?.handleGlobalMouse(event) }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        ) { [weak self] event in
            Task { @MainActor [weak self] in self?.handleGlobalMouse(event) }
            return event
        }
        reconcilePresentationContext()
    }

    func updateMainThreadVisibility(_ visible: Bool) {
        isMainThreadVisible = visible
        reconcilePresentationContext()
    }

    func openAssociatedThread(focusComposer: Bool = false) {
        guard model.voiceSession.threadID != nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await model.showVoiceChat()
            onRestoreMainWindow?(focusComposer)
            panel?.orderOut(nil)
        }
    }

    func startNewVoice() {
        guard !model.voiceSession.isActive else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await model.startNewVoiceChat()
        }
    }

    func resumeVoice() {
        if model.voiceSession.isActive {
            updateMainThreadVisibility(false)
        } else {
            Task { @MainActor [weak self] in await self?.model.retryVoiceChat() }
        }
    }

    func stopVoice() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await model.stopVoiceChat()
        }
    }

    func toggleMicrophone() { model.toggleVoiceMute() }
    func toggleOutput() { model.toggleVoiceOutputMute() }

    func toggleCaptions() {
        stateMachine.reduce(.toggleCaptions)
        updatePanelState()
    }

    func toggleActivity() {
        stateMachine.reduce(.toggleActivity)
        updatePanelState()
    }

    func enableKeyboardInteraction() {
        guard let panel else { return }
        panel.keyboardInteractionEnabled = true
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        panel.makeKey()
        keyboardOffTimer?.invalidate()
        keyboardOffTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.disableKeyboardInteraction() }
        }
    }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        pointerOffTimer?.invalidate()
        keyboardOffTimer?.invalidate()
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        lifecycleObservers.removeAll()
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        globalMouseMonitor = nil
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        localMouseMonitor = nil
        model.voiceSession.onPhaseChanged = nil
        model.onVoicePresentationContextChanged = nil
        UserDefaults.standard.set(false, forKey: Self.openDefaultsKey)
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isDisposed else { return true }
        stopVoice()
        return true
    }

    func windowDidMove(_ notification: Notification) { persistPanelBounds() }
    func windowDidEndLiveResize(_ notification: Notification) { persistPanelBounds() }

    private func sessionPhaseChanged(_ phase: CodexVoiceChatSession.Phase) {
        if stateMachine.state.conversationID != model.voiceSession.threadID {
            isMainThreadVisible = mainThreadVisibilityProvider()
        }
        let surface: CodexVoicePresentationSurface = isMainThreadVisible ? .mainThread : .globalOverlay
        stateMachine.reduce(.session(
            phase: phase,
            threadID: model.voiceSession.threadID,
            surface: surface
        ))
        reconcilePresentationContext()
    }

    private func reconcilePresentationContext() {
        guard !isDisposed else { return }
        let active = model.voiceSession.isActive || model.voiceSession.phase != .inactive
        guard active, let threadID = model.voiceSession.threadID else {
            stateMachine.reduce(.stop)
            UserDefaults.standard.set(false, forKey: Self.openDefaultsKey)
            panel?.orderOut(nil)
            return
        }
        let target: CodexVoicePresentationSurface = isMainThreadVisible ? .mainThread : .globalOverlay
        if stateMachine.state.conversationID != threadID {
            stateMachine.reduce(.launch(threadID: threadID, surface: target))
        }
        if stateMachine.state.surface != target {
            stateMachine.reduce(.handoff(to: target))
            let sequence = stateMachine.state.handoff?.sequence
            if target == .globalOverlay { showPanel() } else { panel?.orderOut(nil) }
            if let sequence {
                stateMachine.reduce(.completeHandoff(sequence: sequence))
            }
        } else if target == .globalOverlay {
            showPanel()
        } else {
            panel?.orderOut(nil)
        }
        stateMachine.reduce(.setMicrophoneMuted(model.voiceSession.isMuted))
        stateMachine.reduce(.setOutputMuted(model.voiceSession.isOutputMuted))
        updatePanelState()
    }

    private func showPanel() {
        let panel = ensurePanel()
        let display = currentDisplay()
        if !panel.isVisible {
            if !hasRestoredInitialFrame {
                panel.setFrame(boundsStore.restoreAndRemember(on: display), display: false)
                hasRestoredInitialFrame = true
            }
            panel.orderFrontRegardless()
            UserDefaults.standard.set(true, forKey: Self.openDefaultsKey)
            panel.resignKey()
            panel.ignoresMouseEvents = true
            panel.keyboardInteractionEnabled = false
        }
        panel.orderFrontRegardless()
    }

    private func ensurePanel() -> CodexVoiceOverlayPanel {
        if let panel { return panel }
        let panel = CodexVoiceOverlayPanel(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 176),
            styleMask: CodexVoiceOverlayWindowPolicy.styleMask,
            backing: .buffered,
            defer: true
        )
        panel.title = "Voice"
        CodexVoiceOverlayWindowPolicy.configure(panel)
        panel.minSize = CGSize(width: 280, height: 140)
        panel.maxSize = CGSize(width: 560, height: 360)
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.window)
        panel.setAccessibilityTitle("Voice chat")
        panel.setAccessibilityHelp("Voice chat controls. The overlay is passive until you move the pointer over it or choose keyboard interaction.")
        panel.onEscape = { [weak self] in self?.stopVoice() }
        panel.contentViewController = NSHostingController<AnyView>(rootView: AnyView(CodexVoiceGlobalOverlayView(
            session: model.voiceSession,
            state: state,
            reduceMotion: model.appearanceSettings.reduceMotion,
            onStartNew: { [weak self] in self?.startNewVoice() },
            onResume: { [weak self] in self?.resumeVoice() },
            onStop: { [weak self] in self?.stopVoice() },
            onToggleMicrophone: { [weak self] in self?.toggleMicrophone() },
            onToggleOutput: { [weak self] in self?.toggleOutput() },
            onToggleCaptions: { [weak self] in self?.toggleCaptions() },
            onToggleActivity: { [weak self] in self?.toggleActivity() },
            onOpenThread: { [weak self] in self?.openAssociatedThread() },
            onFocusComposer: { [weak self] in self?.openAssociatedThread(focusComposer: true) },
            onKeyboardInteraction: { [weak self] in self?.enableKeyboardInteraction() },
            onEscape: { [weak self] in self?.stopVoice() }
        ).codexAgentTheme(model.theme)))
        self.panel = panel
        return panel
    }

    private func updatePanelState() {
        guard let hosting = panel?.contentViewController as? NSHostingController<AnyView> else { return }
        hosting.rootView = AnyView(CodexVoiceGlobalOverlayView(
            session: model.voiceSession,
            state: state,
            reduceMotion: model.appearanceSettings.reduceMotion,
            onStartNew: { [weak self] in self?.startNewVoice() },
            onResume: { [weak self] in self?.resumeVoice() },
            onStop: { [weak self] in self?.stopVoice() },
            onToggleMicrophone: { [weak self] in self?.toggleMicrophone() },
            onToggleOutput: { [weak self] in self?.toggleOutput() },
            onToggleCaptions: { [weak self] in self?.toggleCaptions() },
            onToggleActivity: { [weak self] in self?.toggleActivity() },
            onOpenThread: { [weak self] in self?.openAssociatedThread() },
            onFocusComposer: { [weak self] in self?.openAssociatedThread(focusComposer: true) },
            onKeyboardInteraction: { [weak self] in self?.enableKeyboardInteraction() },
            onEscape: { [weak self] in self?.stopVoice() }
        ).codexAgentTheme(model.theme))
    }

    private func handleGlobalMouse(_ event: NSEvent) {
        guard let panel, panel.isVisible, state.surface == .globalOverlay else { return }
        let inside = panel.frame.contains(NSEvent.mouseLocation)
        if inside {
            pointerOffTimer?.invalidate()
            panel.ignoresMouseEvents = false
        } else if panel.ignoresMouseEvents == false {
            pointerOffTimer?.invalidate()
            pointerOffTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let panel = self.panel else { return }
                    guard !panel.frame.contains(NSEvent.mouseLocation) else { return }
                    panel.ignoresMouseEvents = true
                    panel.keyboardInteractionEnabled = false
                }
            }
        }
        if event.type == .leftMouseDown, inside { panel.orderFrontRegardless() }
    }

    private func disableKeyboardInteraction() {
        guard let panel else { return }
        panel.keyboardInteractionEnabled = false
        if !panel.frame.contains(NSEvent.mouseLocation) { panel.ignoresMouseEvents = true }
        panel.resignKey()
    }

    private func currentDisplay() -> CodexVoiceOverlayDisplay {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        else {
            return CodexVoiceOverlayDisplay(
                identifier: 0,
                bounds: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
                workArea: CGRect(x: 0, y: 0, width: 1_920, height: 1_050)
            )
        }
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let identifier = number.map { CGDirectDisplayID($0.uint32Value) } ?? 0
        return CodexVoiceOverlayDisplay(identifier: identifier, bounds: screen.frame, workArea: screen.visibleFrame)
    }

    private func persistPanelBounds() {
        guard let panel else { return }
        let display = currentDisplay()
        boundsStore.remember(frame: panel.frame, on: display)
        if let data = boundsStore.encoded() { UserDefaults.standard.set(data, forKey: Self.boundsDefaultsKey) }
        CodexVoiceLog.write("overlay.bounds.persisted", fields: ["displayID": String(display.identifier), "resolution": display.resolutionKey])
    }

    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateMainThreadVisibility(false) }
        })
        lifecycleObservers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcilePresentationContext() }
        })
        lifecycleObservers.append(center.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateMainThreadVisibility(false) }
        })
        lifecycleObservers.append(center.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcilePresentationContext() }
        })
        lifecycleObservers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.restoreForCurrentDisplay() }
        })
        lifecycleObservers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                persistPanelBounds()
                stateMachine.reduce(.hide)
                panel?.orderOut(nil)
            }
        })
        lifecycleObservers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                restoreForCurrentDisplay()
                sessionPhaseChanged(model.voiceSession.phase)
            }
        })
    }

    private func restoreForCurrentDisplay() {
        guard let panel else { return }
        let display = currentDisplay()
        panel.setFrame(boundsStore.restoreAndRemember(on: display), display: true)
        if let data = boundsStore.encoded() { UserDefaults.standard.set(data, forKey: Self.boundsDefaultsKey) }
        reconcilePresentationContext()
    }
}
