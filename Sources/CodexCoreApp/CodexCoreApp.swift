import SwiftUI
import AppKit
import CodexCore
import CodexCoreUI

@main
@MainActor
final class CodexCoreApp: NSObject, NSApplicationDelegate {
    private static var sharedDelegate: CodexCoreApp?

    private let clipboardService: any CodexClipboardService = CodexAppKitClipboardService()
    private let preferenceStore: any CodexStringListPreferenceStore = CodexUserDefaultsStringListPreferenceStore()
    private lazy var model = CodexCoreAppModel(
        clipboardService: clipboardService,
        preferenceStore: preferenceStore
    )
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?

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
        configureMainMenu()
        DispatchQueue.main.async { [weak self] in
            self?.showMainWindow()
            NSRunningApplication.current.activate(options: .activateAllWindows)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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

    @objc private func toggleBottomTerminalPanel(_ sender: Any?) {
        showMainWindow()
        model.toggleBottomTerminalPanel()
    }

    @objc private func openBottomTerminal(_ sender: Any?) {
        showMainWindow()
        Task { await model.openBottomTerminalDemo() }
    }

    private func showMainWindow() {
        if mainWindow == nil {
            let controller = NSHostingController(rootView: CodexCoreAppRootView(model: model)
                .codexClipboardService(clipboardService)
                .frame(minWidth: 940, minHeight: 660))
            let window = NSWindow(contentViewController: controller)
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
            window.minSize = NSSize(width: 600, height: 540)
            window.setContentSize(NSSize(width: 1180, height: 760))
            window.isReleasedWhenClosed = false
            window.center()
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        mainWindow?.orderFrontRegardless()
        NSRunningApplication.current.activate(options: .activateAllWindows)
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
        let newWindowItem = NSMenuItem(title: "New Chat", action: #selector(newWindow(_:)), keyEquivalent: "n")
        newWindowItem.target = self
        fileMenu.addItem(newWindowItem)
        fileMenu.addItem(.separator())
        let toggleTerminalItem = NSMenuItem(title: "Toggle Bottom Panel", action: #selector(toggleBottomTerminalPanel(_:)), keyEquivalent: "t")
        toggleTerminalItem.target = self
        toggleTerminalItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(toggleTerminalItem)
        let openTerminalItem = NSMenuItem(title: "Open Terminal Demo", action: #selector(openBottomTerminal(_:)), keyEquivalent: "")
        openTerminalItem.target = self
        fileMenu.addItem(openTerminalItem)
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        let searchItem = NSMenuItem(title: "Command Menu", action: #selector(openCommandPalette(_:)), keyEquivalent: "g")
        searchItem.target = self
        editMenu.addItem(searchItem)
        editItem.submenu = editMenu

        NSApplication.shared.mainMenu = mainMenu
    }
}

struct CodexCoreAppRootView: View {
    @Bindable var model: CodexCoreAppModel
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
            metadata: CodexAboutMetadata(bundle: .main, serverName: model.serverName),
            accountSummary: model.accountMenuSummary,
            appearanceSettings: $model.appearanceSettings,
            sidebarFontSize: $model.sidebarFontSize,
            sidebarFontSizeRange: CodexSidebarFontSizeStorage.fontSizeRange,
            approvalSelection: $model.approvalSelection,
            approvalOptions: model.approvalOptions,
            modelSelection: $model.modelSelection,
            modelOptions: model.modelOptions,
            reasoningSelection: $model.reasoningSelection,
            isBottomPanelVisible: $model.isBottomTerminalVisible,
            gitSettings: $model.gitSettings,
            mcpServers: model.mcpServers,
            isLoadingMCPServers: model.isLoadingMCPServers
        )
        .frame(minWidth: 700, minHeight: 500, alignment: .topLeading)
        .codexAgentTheme(model.theme)
        .tint(model.theme.colors.accent)
    }
}
