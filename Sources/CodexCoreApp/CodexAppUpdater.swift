import AppKit
import Sparkle

enum CodexAppUpdatePolicy {
    static let preferenceKey = "CodexCoreInAppUpdatesEnabled"

    static func isEnabled(in defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: preferenceKey) != nil else { return true }
        return defaults.bool(forKey: preferenceKey)
    }

    static func hasPackagedConfiguration(_ infoDictionary: [String: Any]) -> Bool {
        guard let feedValue = infoDictionary["SUFeedURL"] as? String,
              let feedURL = URL(string: feedValue),
              feedURL.scheme?.lowercased() == "https",
              feedURL.host?.hasSuffix(".invalid") == false,
              let publicKey = infoDictionary["SUPublicEDKey"] as? String,
              !publicKey.hasPrefix("REPLACE_WITH_"),
              Data(base64Encoded: publicKey)?.count == 32
        else { return false }
        return true
    }
}

@MainActor
final class CodexAppUpdater: NSObject {
    private(set) var updaterController: SPUStandardUpdaterController?

    var updater: SPUUpdater? {
        updaterController?.updater
    }

    var checkForUpdatesMenuItem: NSMenuItem {
        let item = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.isEnabled = updaterController != nil
        return item
    }

    init(
        userDefaults: UserDefaults = .standard,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) {
        if CodexAppUpdatePolicy.isEnabled(in: userDefaults),
           CodexAppUpdatePolicy.hasPackagedConfiguration(infoDictionary) {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        }
        super.init()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updaterController?.checkForUpdates(sender)
    }
}
