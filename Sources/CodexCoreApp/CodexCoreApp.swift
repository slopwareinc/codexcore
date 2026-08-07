import SwiftUI
import AppKit
import CodexCore
import CodexCoreUI

private final class CodexMainWindow: NSWindow {
    func alignTrafficLights() {
        guard let closeButton = standardWindowButton(.closeButton),
              let minimizeButton = standardWindowButton(.miniaturizeButton),
              let zoomButton = standardWindowButton(.zoomButton),
              let buttonContainer = closeButton.superview
        else { return }

        let horizontalOffsets = [closeButton, minimizeButton, zoomButton].map {
            $0.frame.minX - closeButton.frame.minX
        }
        let buttonTop = buttonContainer.bounds.maxY - CodexWindowChromeMetrics.trafficLightTopInset

        for (button, horizontalOffset) in zip([closeButton, minimizeButton, zoomButton], horizontalOffsets) {
            var frame = button.frame
            frame.origin.x = CodexWindowChromeMetrics.trafficLightLeadingInset + horizontalOffset
            frame.origin.y = buttonTop - frame.height
            button.setFrameOrigin(frame.origin)
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown,
           event.clickCount == 2,
           styleMask.contains(.resizable),
           titlebarHitTestContains(event.locationInWindow) {
            zoom(nil)
            return
        }
        super.sendEvent(event)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        alignTrafficLights()
    }

    private func titlebarHitTestContains(_ point: NSPoint) -> Bool {
        // The custom full-size content view still reserves this top strip for
        // title-bar interactions, including the native double-click-to-zoom.
        let titlebarHeight = CodexWindowChromeMetrics.titlebarHeight
        return point.y >= frame.height - titlebarHeight
    }
}

@main
@MainActor
final class CodexCoreApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let mainWindowFrameAutosaveName = "CodexCore.MainWindow"
    private static let mainWindowZoomedDefaultsKey = "CodexCore.MainWindow.isZoomed"
    private static let defaultMainWindowContentSize = NSSize(width: 1_416, height: 912)
    private static var sharedDelegate: CodexCoreApp?

    private let clipboardService: any CodexClipboardService = CodexAppKitClipboardService()
    private let preferenceStore: any CodexStringListPreferenceStore = CodexUserDefaultsStringListPreferenceStore()
    private lazy var model = CodexCoreAppModel(
        clipboardService: clipboardService,
        preferenceStore: preferenceStore
    )
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var keyboardShortcutMenuItems: [CodexKeyboardShortcutAction: NSMenuItem] = [:]
    private var voiceOverlayController: CodexVoiceOverlayWindowController?
    private let terminationCoordinator = CodexApplicationTerminationCoordinator()

    static func main() {
        let application = NSApplication.shared
        let delegate = CodexCoreApp()
        sharedDelegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.finishLaunching()
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.startAutomationScheduler()
        configureMainMenu()
        voiceOverlayController = CodexVoiceOverlayWindowController(
            model: model,
            mainThreadVisibilityProvider: { [weak self] in
                guard let self, let mainWindow = self.mainWindow else { return false }
                return NSApp.isActive
                    && mainWindow.isKeyWindow
                    && self.model.currentThreadID == self.model.voiceSession.threadID
            }
        )
        voiceOverlayController?.onRestoreMainWindow = { [weak self] focusComposer in
            self?.showMainWindow(focusComposer: focusComposer)
        }
        voiceOverlayController?.start()
        DispatchQueue.main.async { [weak self] in
            self?.showMainWindow()
            NSRunningApplication.current.activate(options: .activateAllWindows)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.setApplicationActive(true)
        updateVoiceOverlayContext()
    }

    func applicationDidResignActive(_ notification: Notification) {
        model.setApplicationActive(false)
        voiceOverlayController?.updateMainThreadVisibility(false)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        model.setMainWindowKey(true)
        updateVoiceOverlayContext()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        model.setMainWindowKey(false)
        voiceOverlayController?.updateMainThreadVisibility(false)
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        persistMainWindowZoomState(for: window)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        persistMainWindowZoomState(for: window)
    }

    private func persistMainWindowZoomState(for window: NSWindow) {
        guard window === mainWindow else { return }
        UserDefaults.standard.set(window.isZoomed, forKey: Self.mainWindowZoomedDefaultsKey)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The primary window is a hide-on-close surface. Explicit quit still
        // enters applicationShouldTerminate(_:), where the termination
        // coordinator drains the app-server before replying to AppKit.
        false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === mainWindow else { return true }
        sender.saveFrame(usingName: Self.mainWindowFrameAutosaveName)
        persistMainWindowZoomState(for: sender)

        switch CodexPrimaryWindowPersistence.closeAction(
            isTerminationInProgress: terminationCoordinator.state != .running
        ) {
        case .hide:
            sender.orderOut(nil)
            updateVoiceOverlayContext()
            return false
        case .close:
            return true
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        voiceOverlayController?.dispose()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.prepareForTermination()
        terminationCoordinator.requestTermination(
            disconnect: { [weak self] in
                await self?.model.disconnect()
            },
            reply: { [weak sender] in
                sender?.reply(toApplicationShouldTerminate: true)
            }
        )
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard model.enqueueOpenURLs(urls) else { return }
        showMainWindow()
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if model.enqueueOpenURLs(urls) {
            showMainWindow()
        }
        application.reply(toOpenOrPrint: .success)
    }

    @objc private func newWindow(_ sender: Any?) {
        showMainWindow()
        Task { await model.startNewChat() }
    }

    @objc private func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: CodexSettingsWindowView(
                model: model,
                onKeyboardShortcutSettingsChanged: { [weak self] in
                    self?.applyKeyboardShortcutSettings()
                }
            )
                .frame(minWidth: 700, minHeight: 500))
            let window = NSWindow(contentViewController: controller)
            window.title = "Settings"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 980, height: 760))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: .activateAllWindows)
    }

    @objc private func openCommandPalette(_ sender: Any?) {
        showMainWindow()
        model.selectAppRoute(.search)
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        showMainWindow()
        model.toggleSidebarCollapsed()
    }

    private func showMainWindow(focusComposer: Bool = false) {
        if mainWindow == nil {
            let controller = NSHostingController(rootView: CodexCoreAppRootView(
                model: model,
                onKeyboardShortcutSettingsChanged: { [weak self] in
                    self?.applyKeyboardShortcutSettings()
                }
            )
                .codexClipboardService(clipboardService)
                .frame(minWidth: CodexProjectSidebar.minimumExpandedShellWidth, minHeight: 540))
            let window = CodexMainWindow(contentViewController: controller)
            window.title = "CodexCore"
            window.setAccessibilityElement(true)
            window.setAccessibilityRole(.window)
            window.setAccessibilityTitle("CodexCore")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            // Keep window-move confined to the titlebar strip. Dragging the
            // whole background was hijacking in-content drags (sidebar resize,
            // selections) and moving the window instead — especially at small
            // sizes where content sits under the titlebar region.
            window.isMovableByWindowBackground = false
            window.backgroundColor = .clear
            window.minSize = NSSize(width: CodexProjectSidebar.minimumExpandedShellWidth, height: 540)
            window.isReleasedWhenClosed = false
            window.delegate = self
            let restoredSavedFrame = window.setFrameUsingName(Self.mainWindowFrameAutosaveName)
            _ = window.setFrameAutosaveName(Self.mainWindowFrameAutosaveName)
            let restorationPlan = CodexPrimaryWindowPersistence.restorationPlan(
                savedFrame: restoredSavedFrame ? window.frame : nil,
                savedIsZoomed: restoredSavedFrame && (
                    (UserDefaults.standard.object(forKey: Self.mainWindowZoomedDefaultsKey) as? Bool)
                        ?? window.isZoomed
                ),
                visibleFrames: NSScreen.screens.map(\.visibleFrame)
            )
            if restorationPlan.frame == nil {
                // setFrameUsingName can accept a frame for a detached display.
                // Reject it before the window is shown and clear a stale zoom
                // state so the centered fallback is usable.
                if window.isZoomed { window.zoom(nil) }
                UserDefaults.standard.set(false, forKey: Self.mainWindowZoomedDefaultsKey)
                window.setContentSize(Self.defaultMainWindowContentSize)
                window.center()
            } else if restorationPlan.isZoomed != window.isZoomed {
                // Keep the native maximize state when AppKit restored a saved
                // frame without retaining the state itself.
                window.zoom(nil)
            }
            window.alignTrafficLights()
            DispatchQueue.main.async { [weak window] in
                window?.alignTrafficLights()
            }
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        mainWindow?.orderFrontRegardless()
        NSRunningApplication.current.activate(options: .activateAllWindows)
        if focusComposer { model.requestComposerFocus() }
        updateVoiceOverlayContext()
    }

    private func updateVoiceOverlayContext() {
        guard let mainWindow else {
            voiceOverlayController?.updateMainThreadVisibility(false)
            return
        }
        voiceOverlayController?.updateMainThreadVisibility(
            NSApp.isActive && mainWindow.isKeyWindow && model.currentThreadID == model.voiceSession.threadID
        )
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit CodexCore", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        let newWindowItem = NSMenuItem(title: "New Chat", action: #selector(newWindow(_:)), keyEquivalent: "")
        newWindowItem.target = self
        fileMenu.addItem(newWindowItem)
        keyboardShortcutMenuItems[.newChat] = newWindowItem
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(responderMenuItem(title: "Undo", action: "undo:", key: "z"))
        let redoItem = responderMenuItem(title: "Redo", action: "redo:", key: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(responderMenuItem(title: "Cut", action: "cut:", key: "x"))
        editMenu.addItem(responderMenuItem(title: "Copy", action: "copy:", key: "c"))
        editMenu.addItem(responderMenuItem(title: "Paste", action: "paste:", key: "v"))
        editMenu.addItem(responderMenuItem(title: "Select All", action: "selectAll:", key: "a"))
        editMenu.addItem(.separator())
        let searchItem = NSMenuItem(title: "Command Menu", action: #selector(openCommandPalette(_:)), keyEquivalent: "")
        searchItem.target = self
        editMenu.addItem(searchItem)
        keyboardShortcutMenuItems[.search] = searchItem
        editItem.submenu = editMenu

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let toggleSidebarItem = NSMenuItem(
            title: "Toggle Sidebar",
            action: #selector(toggleSidebar(_:)),
            keyEquivalent: ""
        )
        toggleSidebarItem.target = self
        viewMenu.addItem(toggleSidebarItem)
        keyboardShortcutMenuItems[.toggleSidebar] = toggleSidebarItem
        viewItem.submenu = viewMenu

        NSApplication.shared.mainMenu = mainMenu
        applyKeyboardShortcutSettings()
    }

    private func applyKeyboardShortcutSettings() {
        let settings = model.keyboardShortcutSettings
        for action in CodexKeyboardShortcutAction.allCases {
            guard let item = keyboardShortcutMenuItems[action] else { continue }
            let shortcut = settings[action]
            item.keyEquivalent = shortcut.key
            item.keyEquivalentModifierMask = appKitModifierFlags(for: shortcut.modifiers)
        }
    }

    private func appKitModifierFlags(
        for modifiers: CodexKeyboardShortcutModifiers
    ) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }

    private func responderMenuItem(title: String, action: String, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: Selector((action)), keyEquivalent: key)
        item.target = nil
        return item
    }
}

struct CodexCoreAppRootView: View {
    @Bindable var model: CodexCoreAppModel
    let onKeyboardShortcutSettingsChanged: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var didStartInitialConnection = false

    var body: some View {
        ZStack {
            CodexBackdrop()

            Group {
                if model.showsChatWorkspace {
                    CodexCoreAppShell(
                        model: model,
                        onKeyboardShortcutSettingsChanged: onKeyboardShortcutSettingsChanged
                    )
                        .transition(.opacity)
                } else if !model.isConnected {
                    WelcomeFlowView(model: model)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    SignInFlowView(model: model, openURL: openURL)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.9), value: flowKey)
        }
        .codexAgentTheme(model.theme)
        .tint(model.theme.colors.accent)
        // Themes render in both appearances, so the mode is what pins one.
        .preferredColorScheme(model.appearanceSettings.appearanceMode.preferredColorScheme)
        .task {
            guard !didStartInitialConnection else { return }
            didStartInitialConnection = true
            await model.connect()
        }
    }

    private var flowKey: String {
        if model.showsChatWorkspace { return "chat" }
        if !model.isConnected { return "connect" }
        return "sign-in"
    }
}

private struct CodexSettingsWindowView: View {
    @Bindable var model: CodexCoreAppModel
    let onKeyboardShortcutSettingsChanged: () -> Void

    var body: some View {
        CodexSettingsAboutRouteView(
            metadata: CodexAboutMetadata(
                bundle: .main,
                serverName: model.serverName,
                fallbackAppName: "CodexCore",
                fallbackCopyright: "© Slopware"
            ),
            accountSummary: model.accountMenuSummary,
            appearanceSettings: $model.appearanceSettings,
            approvalSelection: $model.approvalSelection,
            approvalOptions: model.approvalOptions,
            modelSelection: $model.modelSelection,
            modelOptions: model.modelOptions,
            reasoningSelection: $model.reasoningSelection,
            isBottomPanelVisible: .constant(false),
            keyboardShortcutSettings: $model.keyboardShortcutSettings,
            gitSettings: $model.gitSettings,
            newThreadHistoryMode: $model.newThreadHistoryMode,
            followUpBehavior: $model.followUpBehavior,
            mcpServers: model.mcpServers,
            isLoadingMCPServers: model.isLoadingMCPServers,
            onKeyboardShortcutSettingsChanged: onKeyboardShortcutSettingsChanged
        )
        .frame(minWidth: 700, minHeight: 500, alignment: .topLeading)
        .codexAgentTheme(model.theme)
        .tint(model.theme.colors.accent)
        .preferredColorScheme(model.appearanceSettings.appearanceMode.preferredColorScheme)
    }
}
