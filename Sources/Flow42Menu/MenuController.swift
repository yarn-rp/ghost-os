// MenuController.swift - Owns the NSStatusItem and reflects state changes.
//
// The status icon swaps glyph + tint depending on the derived state:
//   .idle      → grey    "dot.circle"
//   .recording → magenta "record.circle.fill"
//   .driving   → orange  "bolt.circle.fill"
//   .watching  → cyan    "eye.circle.fill"
//
// Click opens a popover; for now the popover just shows mode + last label as
// a placeholder. The full event timeline lives in TimelineView (Module 2 of
// the plan) which will be wired in later.
//
// Right-click opens a quick menu (Quit, Open recordings folder, …).

import AppKit
import Combine
import Flow42Core
import SwiftUI

@MainActor
final class MenuController {

    private let statusItem: NSStatusItem
    private let stateClient: StateClient
    private let panelController: PlayPanelController
    private let timelineModel: TimelineModel
    private let recordingsModel: RecordingsModel
    private let popover: NSPopover
    private var cancellable: AnyCancellable?

    init(stateClient: StateClient, panelController: PlayPanelController) {
        self.stateClient = stateClient
        self.panelController = panelController
        self.timelineModel = TimelineModel(stateClient: stateClient)
        self.recordingsModel = RecordingsModel()
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.popover.behavior = .transient
        self.popover.contentSize = NSSize(width: 380, height: 560)

        configureStatusItem()
        updateAppearance(for: stateClient.state.derivedState)

        cancellable = stateClient.$state.sink { [weak self] state in
            self?.updateAppearance(for: state.derivedState)
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.action = #selector(handleClick)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func handleClick() {
        // Either kind of click implies "I'm interacting with Flow42" —
        // wake the main app if it isn't running so deep links + the
        // chat handoff have a window to land in. Best-effort, async,
        // non-blocking: the popover still opens immediately.
        ensureFlow42AppRunning()
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            openContextMenu()
        } else {
            togglePopover()
        }
    }

    /// Ensure `Flow42App` is running. Resolves the binary by walking up
    /// from this menu app's executable dir (sibling at the same level
    /// in dev builds; same .app/Contents/MacOS path in installed
    /// builds). No-op if it's already running.
    ///
    /// Symmetric to the CLI's `ensureCompanionApps()` — either side
    /// pulls the other up. Failure is silent because the click should
    /// never feel laggy while we wait on a process spawn.
    private func ensureFlow42AppRunning() {
        let already = NSWorkspace.shared.runningApplications.contains { app in
            app.executableURL?.lastPathComponent == "Flow42App"
        }
        if already { return }

        // Walk up from this binary to find a sibling Flow42App.
        let menuExe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let menuDir = (menuExe as NSString).deletingLastPathComponent
        let candidate = (menuDir as NSString).appendingPathComponent("Flow42App")
        guard FileManager.default.isExecutableFile(atPath: candidate) else { return }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: candidate)
        if let nullR = FileHandle(forReadingAtPath: "/dev/null") {
            task.standardInput = nullR
        }
        if let nullW = FileHandle(forWritingAtPath: "/dev/null") {
            task.standardOutput = nullW
            task.standardError = nullW
        }
        try? task.run()
    }

    private func openContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open recordings folder", action: #selector(openRecordings), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Open annotations folder", action: #selector(openAnnotations), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Install Chrome extension…",
            action: #selector(installChromeExtension),
            keyEquivalent: ""
        ).target = self
        // Browser-mode submenu — A/B between extension-mediated and native-only.
        menu.addItem(buildBrowserModeItem())
        menu.addItem(.separator())
        if LaunchAtLogin.isAvailable {
            let item = menu.addItem(
                withTitle: "Launch at login",
                action: #selector(toggleLaunchAtLogin),
                keyEquivalent: ""
            )
            item.target = self
            item.state = LaunchAtLogin.isRegistered ? .on : .off
        } else {
            let item = menu.addItem(
                withTitle: "Launch at login (install Flow42.app to enable)",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Flow42", action: #selector(quit), keyEquivalent: "q")
            .target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.toggle()
    }

    /// Submenu: "Browser mode → Auto / Native / Extension". Picks persist
    /// to ~/.flow42/browser-mode and apply to every subsequent
    /// recording. The current pick gets a checkmark.
    private func buildBrowserModeItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Browser mode", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Browser mode")
        let current = BrowserMode.current()
        for mode in [BrowserMode.auto, .native, .extension] {
            let label: String = {
                switch mode {
                case .auto: return "Auto (extension when available)"
                case .native: return "Native only (drop the extension)"
                case .extension: return "Extension only (strict)"
                }
            }()
            let item = NSMenuItem(
                title: label,
                action: #selector(setBrowserMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (mode == current) ? .on : .off
            sub.addItem(item)
        }
        parent.submenu = sub
        return parent
    }

    @objc private func setBrowserMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = BrowserMode(rawValue: raw) else { return }
        BrowserMode.setPersistent(mode)
    }

    /// Streamline the one manual step we still need on the user's regular
    /// Chrome: drop the unpacked extension into chrome://extensions. We
    /// resolve the dist path, copy it to the clipboard, open Chrome's
    /// extensions page, and surface a Notification Center alert with the
    /// click-by-click steps.
    @objc private func installChromeExtension() {
        guard let dist = ChromeExtensionInstaller.distPath() else {
            ChromeExtensionInstaller.alertMissingDist()
            return
        }
        ChromeExtensionInstaller.run(distPath: dist)
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        recordingsModel.reload()
        popover.contentViewController = NSHostingController(
            rootView: TimelineView(
                stateClient: stateClient,
                model: timelineModel,
                recordingsModel: recordingsModel,
                panelController: panelController
            )
        )
        popover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .minY
        )
    }

    private func updateAppearance(for state: DerivedState) {
        guard let button = statusItem.button else { return }
        let symbolName: String
        let tint: NSColor
        let title: String
        switch state {
        case .idle:
            symbolName = "dot.circle"
            tint = .secondaryLabelColor
            title = "Flow42 — idle"
        case .recording:
            symbolName = "record.circle.fill"
            tint = NSColor(
                red: 0xFF/255, green: 0x3E/255, blue: 0xCB/255, alpha: 1.0
            )  // magenta
            title = "Flow42 — recording"
        case .driving:
            symbolName = "bolt.circle.fill"
            tint = NSColor(
                red: 0xFF/255, green: 0x8A/255, blue: 0x3D/255, alpha: 1.0
            )  // orange
            title = "Flow42 — driving"
        case .watching:
            symbolName = "eye.circle.fill"
            tint = NSColor(
                red: 0x3D/255, green: 0xB6/255, blue: 0xFF/255, alpha: 1.0
            )  // cyan
            title = "Flow42 — watching"
        }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)?
            .withSymbolConfiguration(config)
        image?.isTemplate = (state == .idle)
        button.image = image
        if state != .idle {
            button.contentTintColor = tint
        } else {
            button.contentTintColor = nil
        }
        button.toolTip = title
    }

    @objc private func openRecordings() {
        let url = URL(fileURLWithPath: Flow42Paths.flowsRoot())
        NSWorkspace.shared.open(url)
    }

    @objc private func openAnnotations() {
        let url = URL(fileURLWithPath: AnnotationStore.rootDir())
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

