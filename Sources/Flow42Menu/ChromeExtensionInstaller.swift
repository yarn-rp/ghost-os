// ChromeExtensionInstaller.swift - Walk the user through loading our
// unpacked Chrome extension into their regular Chrome profile.
//
// Recording (DOM event capture) doesn't need CDP — only the extension and
// the native-messaging manifest. The native-messaging manifest is registered
// once by `flow42 install` (or `setup-browser`); the only step that's still
// manual is loading the unpacked extension via chrome://extensions. This
// helper makes that step as cheap as possible: copy the dist path, open
// Chrome to chrome://extensions, surface a notification with the steps.
//
// We deliberately don't try to script chrome://extensions itself — that
// page is internal-only and AppleScript / CDP can't drive it. The user
// clicks "Load unpacked", pastes the path we put on the clipboard, hits
// Enter. ~5 seconds total.

import AppKit
import Flow42Core
import Foundation
import UserNotifications

@MainActor
enum ChromeExtensionInstaller {

    /// Locate the unpacked extension dist directory.
    /// Resolution order:
    ///   1. Bundled inside Flow42.app at Contents/Resources/chrome-extension/
    ///   2. The repo's `dist/` folder, found by walking up from this binary
    ///   3. Common neighbor paths used during dev
    static func distPath() -> String? {
        let fm = FileManager.default

        // 1. Bundled
        if let resources = Bundle.main.resourceURL {
            let candidate = resources
                .appendingPathComponent("chrome-extension")
                .path
            if fm.fileExists(atPath:
                (candidate as NSString).appendingPathComponent("manifest.json")
            ) {
                return candidate
            }
        }

        // 2. Walk up from the running binary
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<8 {
            for parent in [dir, dir.deletingLastPathComponent()] {
                let candidate = parent.appendingPathComponent("dist").path
                if fm.fileExists(atPath:
                    (candidate as NSString).appendingPathComponent("manifest.json")
                ) {
                    return candidate
                }
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Run the install flow: copy path, open Chrome, post notification.
    static func run(distPath: String) {
        // 1. Clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(distPath, forType: .string)

        // 2. Open chrome://extensions in Chrome (regular profile — no flag)
        let chromeAppPath = "/Applications/Google Chrome.app"
        let extensionsURL = URL(string: "chrome://extensions")!
        NSWorkspace.shared.open(
            [extensionsURL],
            withApplicationAt: URL(fileURLWithPath: chromeAppPath),
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in }

        // 3. Steps via Notification Center (best-effort) and an alert
        //    fallback so the user is never left guessing.
        showSteps(distPath: distPath)
    }

    /// Surface the steps. Tries a Notification Center banner first
    /// (non-blocking, non-intrusive); always also shows a small alert with
    /// the same content because the user needs to read the steps before
    /// clicking around in Chrome.
    private static func showSteps(distPath: String) {
        let title = "Install Flow42 extension"
        let body = """
        1. Toggle "Developer mode" (top-right of chrome://extensions)
        2. Click "Load unpacked"
        3. Paste this path (already copied):
           \(distPath)
        4. Press Enter.
        Extension id will be hhlhfpnngoonnimpgbccgcogcanibkkg.
        """

        // Notification Center
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { _, _ in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = nil
            let req = UNNotificationRequest(
                identifier: "com.web42.flow42.menu.install-extension",
                content: content,
                trigger: nil
            )
            center.add(req, withCompletionHandler: nil)
        }

        // Alert (always shown — the steps are too long for a banner alone)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Finder")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([
                URL(fileURLWithPath: distPath)
            ])
        }
    }

    /// Called when we can't find the dist directory at all (development
    /// outside the repo, or a busted .app bundle).
    static func alertMissingDist() {
        let alert = NSAlert()
        alert.messageText = "Couldn't find the Flow42 Chrome extension"
        alert.informativeText = """
        We expected to find an unpacked extension at one of:
          • Contents/Resources/chrome-extension/ inside Flow42.app
          • <repo>/dist/

        If you're running from source, build the extension first:
          npm run build (or vite build)

        Then try again.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
