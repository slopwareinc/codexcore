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
    private var voiceOverlayController: CodexVoiceOverlayWindowController?
    private var terminationReplyInFlight = false

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
        model.onDockStateChanged = { [weak self] in
            self?.updateDockBadge()
        }
        model.onNotificationOpen = { [weak self] threadID in
            guard let self else { return }
            showMainWindow()
            guard let threadID else { return }
            Task { await model.resumeChat(id: threadID) }
        }
        model.startAutomationScheduler()
        configureMainMenu()
        updateDockBadge()
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.hasInFlightWork
    }

    func applicationWillTerminate(_ notification: Notification) {
        voiceOverlayController?.dispose()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let newChatItem = NSMenuItem(
            title: "New Chat",
            action: #selector(newWindow(_:)),
            keyEquivalent: ""
        )
        newChatItem.target = self
        menu.addItem(newChatItem)

        let chats = model.allSidebarChats.sorted { lhs, rhs in
            let lhsRunning = model.canonicalThreadStatusEntries[lhs.id]?.status == .running
            let rhsRunning = model.canonicalThreadStatusEntries[rhs.id]?.status == .running
            if lhsRunning != rhsRunning { return lhsRunning }
            return (lhs.recencyAt ?? lhs.updatedAt ?? lhs.createdAt ?? 0)
                > (rhs.recencyAt ?? rhs.updatedAt ?? rhs.createdAt ?? 0)
        }
        guard !chats.isEmpty else { return menu }

        menu.addItem(.separator())
        for chat in chats.prefix(9) {
            let isRunning = model.canonicalThreadStatusEntries[chat.id]?.status == .running
            let isUnread = model.canonicalThreadStatusEntries[chat.id]?.hasUnreadWhileInactive == true
            let prefix = isRunning ? "⟳ " : isUnread ? "• " : ""
            let item = NSMenuItem(
                title: "\(prefix)\(chat.title)",
                action: #selector(openDockChat(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = chat.id
            menu.addItem(item)
        }
        return menu
    }

    private func updateDockBadge() {
        let count = model.dockAttentionCount
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationReplyInFlight else { return .terminateLater }
        if model.hasInFlightWork {
            let alert = NSAlert()
            alert.messageText = "Quit CodexCore?"
            alert.informativeText = model.terminationConfirmationMessage
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return .terminateCancel
            }
        }
        terminationReplyInFlight = true
        Task { @MainActor [weak self, weak sender] in
            guard let self else {
                sender?.reply(toApplicationShouldTerminate: true)
                return
            }
            await self.model.disconnect()
            sender?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    @objc private func newWindow(_ sender: Any?) {
        showMainWindow()
        Task { await model.startNewChat() }
    }

    @objc private func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: CodexSettingsWindowView(model: model)
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
            let controller = NSHostingController(rootView: CodexCoreAppRootView(model: model)
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
            if !restoredSavedFrame {
                window.setContentSize(Self.defaultMainWindowContentSize)
                window.center()
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
        mainMenu.autoenablesItems = true

        let appItem = NSMenuItem(title: "CodexCore", action: nil, keyEquivalent: "")
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(
            title: "About CodexCore",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApplication.shared
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        let signOutItem = NSMenuItem(title: "Sign Out", action: #selector(signOut(_:)), keyEquivalent: "")
        signOutItem.target = self
        appMenu.addItem(signOutItem)
        appMenu.addItem(.separator())
        let servicesMenu = NSMenu(title: "Services")
        NSApp.servicesMenu = servicesMenu
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())
        let hideItem = NSMenuItem(title: "Hide CodexCore", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.target = NSApplication.shared
        appMenu.addItem(hideItem)
        let hideOthersItem = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.target = NSApplication.shared
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        let showAllItem = NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAllItem.target = NSApplication.shared
        appMenu.addItem(showAllItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit CodexCore",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApplication.shared
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        let newWindowItem = NSMenuItem(title: "New Chat", action: #selector(newWindow(_:)), keyEquivalent: "n")
        newWindowItem.target = self
        fileMenu.addItem(newWindowItem)
        fileMenu.addItem(.separator())
        let copyWorkingDirectoryItem = NSMenuItem(
            title: "Copy Working Directory",
            action: #selector(copyWorkingDirectory(_:)),
            keyEquivalent: ""
        )
        copyWorkingDirectoryItem.target = self
        fileMenu.addItem(copyWorkingDirectoryItem)
        let copySessionIDItem = NSMenuItem(
            title: "Copy Session ID",
            action: #selector(copySessionID(_:)),
            keyEquivalent: ""
        )
        copySessionIDItem.target = self
        fileMenu.addItem(copySessionIDItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(responderMenuItem(title: "Close Window", action: "performClose:", key: "w"))
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
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
        let pasteAndMatchStyleItem = responderMenuItem(
            title: "Paste and Match Style",
            action: "pasteAsPlainText:",
            key: "v"
        )
        pasteAndMatchStyleItem.keyEquivalentModifierMask = [.command, .option, .shift]
        editMenu.addItem(pasteAndMatchStyleItem)
        editMenu.addItem(responderMenuItem(title: "Delete", action: "delete:", key: "\u{8}"))
        editMenu.addItem(responderMenuItem(title: "Select All", action: "selectAll:", key: "a"))
        editMenu.addItem(.separator())
        let searchItem = NSMenuItem(title: "Command Menu", action: #selector(openCommandPalette(_:)), keyEquivalent: "g")
        searchItem.target = self
        editMenu.addItem(searchItem)
        editItem.submenu = editMenu

        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let toggleSidebarItem = NSMenuItem(
            title: "Toggle Sidebar",
            action: #selector(toggleSidebar(_:)),
            keyEquivalent: "s"
        )
        toggleSidebarItem.target = self
        toggleSidebarItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(toggleSidebarItem)
        viewMenu.addItem(.separator())
        let previousChatItem = NSMenuItem(
            title: "Previous Chat",
            action: #selector(previousChat(_:)),
            keyEquivalent: "["
        )
        previousChatItem.target = self
        viewMenu.addItem(previousChatItem)
        let nextChatItem = NSMenuItem(
            title: "Next Chat",
            action: #selector(nextChat(_:)),
            keyEquivalent: "]"
        )
        nextChatItem.target = self
        viewMenu.addItem(nextChatItem)
        viewMenu.addItem(.separator())
        for index in 0..<9 {
            let item = NSMenuItem(
                title: "Switch to Chat \(index + 1)",
                action: #selector(selectChatShortcut(_:)),
                keyEquivalent: "\(index + 1)"
            )
            item.target = self
            item.representedObject = index
            viewMenu.addItem(item)
        }
        viewMenu.addItem(.separator())
        let fullScreenItem = NSMenuItem(
            title: "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreenItem.target = nil
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreenItem)
        viewItem.submenu = viewMenu

        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        let minimizeItem = responderMenuItem(title: "Minimize", action: "performMiniaturize:", key: "m")
        windowMenu.addItem(minimizeItem)
        windowMenu.addItem(responderMenuItem(title: "Zoom", action: "performZoom:", key: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(responderMenuItem(title: "Bring All to Front", action: "arrangeInFront:", key: ""))
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        let helpCommandItem = NSMenuItem(title: "CodexCore Help", action: #selector(showHelp(_:)), keyEquivalent: "")
        helpCommandItem.target = self
        helpMenu.addItem(helpCommandItem)
        helpItem.submenu = helpMenu

        NSApplication.shared.mainMenu = mainMenu
    }

    private func responderMenuItem(title: String, action: String, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: Selector((action)), keyEquivalent: key)
        item.target = nil
        return item
    }

    @objc private func signOut(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Sign Out of Codex?"
        alert.informativeText = "This disconnects the current account from CodexCore."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Sign Out")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await model.signOut() }
    }

    @objc private func copyWorkingDirectory(_ sender: Any?) {
        model.copyWorkingDirectory()
    }

    @objc private func copySessionID(_ sender: Any?) {
        model.copySessionID()
    }

    @objc private func previousChat(_ sender: Any?) {
        selectAdjacentChat(offset: -1)
    }

    @objc private func nextChat(_ sender: Any?) {
        selectAdjacentChat(offset: 1)
    }

    @objc private func selectChatShortcut(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int,
              model.allSidebarChats.indices.contains(index)
        else { return }
        let chat = model.allSidebarChats[index]
        showMainWindow()
        Task { await model.selectSidebarChat(chat) }
    }

    private func selectAdjacentChat(offset: Int) {
        let chats = model.allSidebarChats
        guard !chats.isEmpty else { return }
        let currentIndex = model.currentThreadID.flatMap { currentID in
            chats.firstIndex { $0.id == currentID }
        }
        let base = currentIndex ?? (offset > 0 ? -1 : chats.count)
        let index = (base + offset + chats.count) % chats.count
        let chat = chats[index]
        showMainWindow()
        Task { await model.selectSidebarChat(chat) }
    }

    @objc private func openDockChat(_ sender: NSMenuItem) {
        guard let threadID = sender.representedObject as? String else { return }
        showMainWindow()
        Task { await model.resumeChat(id: threadID) }
    }

    @objc private func showHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "CodexCore Help"
        alert.informativeText = "Use New Chat to start a conversation, or Command Menu to search chats and commands."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(signOut(_:)):
            return model.isAuthenticated
        case #selector(copySessionID(_:)):
            return model.currentThreadID != nil
        case #selector(selectChatShortcut(_:)):
            return (menuItem.representedObject as? Int).map(model.allSidebarChats.indices.contains) ?? false
        case #selector(previousChat(_:)), #selector(nextChat(_:)):
            return model.allSidebarChats.count > 1
        default:
            return true
        }
    }
}

struct CodexCoreAppRootView: View {
    @Bindable var model: CodexCoreAppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @State private var didStartInitialConnection = false

    var body: some View {
        ZStack {
            CodexBackdrop()

            Group {
                if model.showsChatWorkspace {
                    CodexCoreAppShell(model: model)
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
        .onAppear {
            CodexThemedAppIcon.apply(
                settings: model.appearanceSettings,
                colorScheme: colorScheme
            )
        }
        .onChange(of: model.appearanceSettings) { _, settings in
            CodexThemedAppIcon.apply(settings: settings, colorScheme: colorScheme)
        }
        .onChange(of: colorScheme) { _, scheme in
            CodexThemedAppIcon.apply(settings: model.appearanceSettings, colorScheme: scheme)
        }
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
            agentsDocumentStore: model.agentsDocumentStore,
            codexHomePath: model.codexHome.path,
            workingDirectory: model.workspacePath,
            modelSelection: $model.modelSelection,
            modelOptions: model.modelOptions,
            reasoningSelection: $model.reasoningSelection,
            isBottomPanelVisible: .constant(false),
            newThreadHistoryMode: $model.newThreadHistoryMode,
            mcpServers: model.mcpServers,
            isLoadingMCPServers: model.isLoadingMCPServers,
            serverDiagnostics: model.serverDiagnostics,
            isLoadingServerDiagnostics: model.isLoadingServerDiagnostics,
            serverDiagnosticsError: model.serverDiagnosticsError,
            onRefreshServerDiagnostics: {
                Task { await model.refreshServerDiagnostics() }
            },
            threadSections: model.threadSections,
            isLoadingThreadSections: model.isLoadingThreadSections,
            threadSectionsError: model.threadSectionsError,
            onRefreshThreadSections: {
                Task { await model.refreshThreadSections() }
            },
            onCreateThreadSection: { name, appearance in
                Task { await model.createThreadSection(name: name, appearance: appearance) }
            },
            onUpdateThreadSection: { id, name, appearance in
                Task { await model.updateThreadSection(id: id, name: name, appearance: appearance) }
            },
            onDeleteThreadSection: { id in
                Task { await model.deleteThreadSection(id: id) }
            }
        )
        .frame(minWidth: 700, minHeight: 500, alignment: .topLeading)
        .codexAgentTheme(model.theme)
        .tint(model.theme.colors.accent)
        .preferredColorScheme(model.appearanceSettings.appearanceMode.preferredColorScheme)
    }
}
