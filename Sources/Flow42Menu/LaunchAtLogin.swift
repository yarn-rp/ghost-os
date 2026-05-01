// LaunchAtLogin.swift - macOS-native launch-at-login via SMAppService.
//
// The Flow42 menu app is meant to run silently in the background all the
// time. SMAppService.mainApp (macOS 13+) is the modern, sandbox-friendly,
// no-helper-tool way to register the bundle to launch when the user logs in.
//
// Two key facts about SMAppService.mainApp:
//   - It only works when the binary lives inside an .app bundle. A plain
//     `swift run Flow42Menu` reports `.notFound` and registration silently
//     fails — that's expected for the dev workflow.
//   - The user can revoke the permission in System Settings → General →
//     Login Items at any time, and we'll see that as `.notRegistered` next
//     time we check.

import Foundation
import ServiceManagement

@MainActor
enum LaunchAtLogin {

    /// True when launch-at-login is something we can register for in this
    /// process — i.e. we're running from an .app bundle, not via `swift run`.
    static var isAvailable: Bool {
        // SMAppService.mainApp.status returns .notFound when there's no
        // bundle to register; treat that as "not available."
        SMAppService.mainApp.status != .notFound
    }

    static var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register Flow42 to launch at login. Returns true on success.
    @discardableResult
    static func register() -> Bool {
        guard isAvailable else { return false }
        do {
            try SMAppService.mainApp.register()
            return true
        } catch {
            FileHandle.standardError.write(Data(
                "[Flow42Menu] launch-at-login register failed: \(error.localizedDescription)\n".utf8
            ))
            return false
        }
    }

    @discardableResult
    static func unregister() -> Bool {
        guard isAvailable else { return false }
        do {
            try SMAppService.mainApp.unregister()
            return true
        } catch {
            FileHandle.standardError.write(Data(
                "[Flow42Menu] launch-at-login unregister failed: \(error.localizedDescription)\n".utf8
            ))
            return false
        }
    }

    /// Toggle helper for the menu item.
    static func toggle() {
        if isRegistered { _ = unregister() } else { _ = register() }
    }

    /// On first launch from a packaged .app, opt the user in automatically.
    /// We track "have we asked once" via UserDefaults so we don't keep
    /// re-registering after the user explicitly turned it off.
    static func ensureRegisteredOnFirstLaunch() {
        guard isAvailable else { return }
        let key = "com.web42.flow42.launchAtLogin.askedOnce"
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: key) { return }
        defaults.set(true, forKey: key)
        if !isRegistered {
            _ = register()
        }
    }
}
