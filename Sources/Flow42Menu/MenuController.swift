// MenuController.swift - Owns the NSStatusItem and reflects mode changes.
//
// The status icon swaps glyph + tint depending on the current mode:
//   .idle        → grey "dot.circle"
//   .recording   → magenta "record.circle.fill"
//   .autonomous  → orange "bolt.circle.fill"
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
    private let timelineModel: TimelineModel
    private let recordingsModel: RecordingsModel
    private let popover: NSPopover
    private var cancellable: AnyCancellable?

    init(stateClient: StateClient) {
        self.stateClient = stateClient
        self.timelineModel = TimelineModel(stateClient: stateClient)
        self.recordingsModel = RecordingsModel()
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.popover.behavior = .transient
        self.popover.contentSize = NSSize(width: 380, height: 560)

        configureStatusItem()
        updateAppearance(for: stateClient.state.mode)

        cancellable = stateClient.$state.sink { [weak self] state in
            self?.updateAppearance(for: state.mode)
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.action = #selector(handleClick)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            openContextMenu()
        } else {
            togglePopover()
        }
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
    /// to ~/.openclaw/flow42/browser-mode and apply to every subsequent
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
                recordingsModel: recordingsModel
            )
        )
        popover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .minY
        )
    }

    private func updateAppearance(for mode: AppMode) {
        guard let button = statusItem.button else { return }
        let symbolName: String
        let tint: NSColor
        let title: String
        switch mode {
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
        case .autonomous:
            symbolName = "bolt.circle.fill"
            tint = NSColor(
                red: 0xFF/255, green: 0x8A/255, blue: 0x3D/255, alpha: 1.0
            )  // orange
            title = "Flow42 — autonomous"
        }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)?
            .withSymbolConfiguration(config)
        image?.isTemplate = (mode == .idle)
        button.image = image
        if mode != .idle {
            button.contentTintColor = tint
        } else {
            button.contentTintColor = nil
        }
        button.toolTip = title
    }

    @objc private func openRecordings() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home
            .appendingPathComponent(".openclaw")
            .appendingPathComponent("flow42")
            .appendingPathComponent("recipes")
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

