// FrontmostApp.swift - Reliable frontmost-app detection for the recorder.
//
// `NSWorkspace.shared.frontmostApplication` is the documented entry point but
// it's unreliable: Universal Control while the cursor is crossing between
// Macs, screen savers, the login window, etc. all hijack frontmost-reporting
// without owning a user-visible window. The screenshot capture path doesn't
// have this problem — it asks "what's the topmost on-screen window?" and
// gets the right answer every time.
//
// We use the same source of truth here. Topmost on-screen window's owner
// is the app the user is actually looking at and clicking in. NSWorkspace is
// only consulted as a fallback when no on-screen window is available
// (a screen-locked state, basically).

import AppKit
import CoreGraphics
import Foundation

nonisolated public enum FrontmostApp {

    /// System processes we never want to attribute user actions to. They
    /// can briefly own visible windows (popovers, overlays) but they're not
    /// where the user's focus is.
    private static let denyList: Set<String> = [
        "com.apple.universalcontrol",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.dock",
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine",
        "com.apple.WindowManager",
        "com.apple.systemuiserver",
    ]

    public struct Info: Sendable {
        public let pid: pid_t
        public let name: String
        public let bundleId: String
    }

    /// The "real" frontmost app from the user's point of view — the owner of
    /// the topmost regular on-screen window. This is the same source of truth
    /// the screenshot capture uses, so the action's `app` field and the
    /// captured `screenshot` will always agree.
    public static func effective() -> Info? {
        if let info = resolveFromTopmostWindow() { return info }
        // Last-resort fallback: NSWorkspace, with the deny-list applied.
        if let app = NSWorkspace.shared.frontmostApplication,
           let bid = app.bundleIdentifier,
           !denyList.contains(bid) {
            return Info(
                pid: app.processIdentifier,
                name: app.localizedName ?? "Unknown",
                bundleId: bid
            )
        }
        return nil
    }

    /// Convenience for sites that just need a (name, bundleId) tuple.
    public static func nameAndBundle() -> (name: String, bundleId: String) {
        guard let info = effective() else { return ("Unknown", "") }
        return (info.name, info.bundleId)
    }

    // MARK: - Internals

    private static func resolveFromTopmostWindow() -> Info? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
            as? [[CFString: Any]] else { return nil }
        for info in list {
            // layer 0 = regular app window. Higher layers are menus, popovers,
            // dock, etc. Skip those.
            if let layer = info[kCGWindowLayer] as? Int, layer != 0 { continue }
            if let bounds = info[kCGWindowBounds] as? [String: Any] {
                let h = bounds["Height"] as? Double ?? 0
                let w = bounds["Width"] as? Double ?? 0
                if h < 100 || w < 100 { continue }
            }
            guard let pid = info[kCGWindowOwnerPID] as? pid_t else { continue }
            if let app = NSRunningApplication(processIdentifier: pid),
               let bid = app.bundleIdentifier {
                if denyList.contains(bid) { continue }
                return Info(
                    pid: pid,
                    name: app.localizedName ?? (info[kCGWindowOwnerName] as? String ?? "Unknown"),
                    bundleId: bid
                )
            }
            // No NSRunningApplication entry (rare); use what CGWindowList tells us.
            if let name = info[kCGWindowOwnerName] as? String {
                return Info(pid: pid, name: name, bundleId: "")
            }
        }
        return nil
    }
}
