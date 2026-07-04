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
            let controller = NSHostingController(rootView: CodexSettingsView(model: model)
                .codexAgentTheme(model.themePreset.theme)
                .tint(model.themePreset.theme.colors.accent))
            let window = NSWindow(contentViewController: controller)
            window.title = "Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
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
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.minSize = NSSize(width: 940, height: 660)
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
        .codexAgentTheme(model.themePreset.theme)
        .tint(model.themePreset.theme.colors.accent)
        .task {
            guard !didStartInitialConnection else { return }
            didStartInitialConnection = true
            await model.connect()
        }
        .toolbar {
            if model.showsChatWorkspace {
                ToolbarItemGroup(placement: .automatic) {
                    Button {
                        model.toggleBottomTerminalPanel()
                    } label: {
                        Label("Toggle bottom panel", systemImage: "rectangle.bottomthird.inset.filled")
                    }
                    .help("Toggle bottom panel")
                    .keyboardShortcut("t", modifiers: [.command, .shift])

                    Button {
                        Task { await model.openBottomTerminalDemo() }
                    } label: {
                        Label("Open terminal", systemImage: "terminal")
                    }
                    .help("Open terminal")
                }
            }
        }
    }

    private var flowKey: String {
        if model.showsChatWorkspace { return "chat" }
        if !model.isConnected { return "connect" }
        return "sign-in"
    }
}

private struct CodexSettingsView: View {
    @Environment(\.codexAgentTheme) private var theme
    @Bindable var model: CodexCoreAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Settings")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Text("Customize the CodexCore app.")
                    .font(theme.fonts.chat)
                    .foregroundStyle(theme.colors.textSecondary)
            }

            Divider().overlay(theme.colors.border)

            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Theme")
                        .font(theme.fonts.label)
                        .foregroundStyle(theme.colors.textPrimary)
                    Text("Applies to the whole workspace, including side chats and subagents.")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                }

                Spacer(minLength: 24)

                ThemePresetPicker(model: model)
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 420, height: 220, alignment: .topLeading)
        .background(theme.colors.canvas)
    }
}

private struct ThemePresetPicker: View {
    @Bindable var model: CodexCoreAppModel

    var body: some View {
        Picker("Theme", selection: $model.themePreset) {
            ForEach(CodexAgentThemePreset.allCases) { preset in
                Text(preset.displayName).tag(preset)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 156)
        .codexGlass(Capsule(), interactive: true)
    }
}
