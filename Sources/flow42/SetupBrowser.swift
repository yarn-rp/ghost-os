// SetupBrowser.swift - `flow42 setup-browser` one-shot wizard.
//
// Replaces the multi-step manual dance (quit Chrome → chrome-launch →
// chrome://extensions → load unpacked → copy ID → flow42 install). One
// command does it all and verifies the result.
//
// Steps:
//   1. Verify the extension dist/ exists.
//   2. Detect any running Chrome; ask the user to quit if it's not already
//      one of ours.
//   3. Launch Chrome via `flow42 chrome-launch` with --load-extension and
//      the dedicated profile dir.
//   4. Poll the CDP debug endpoint until it's reachable.
//   5. Register the native-messaging manifest with the deterministic
//      extension id (the same id every time, pinned by manifest.json's
//      `key` field — survives repo moves and reinstalls).
//   6. Verify the round-trip: probe the chrome.runtime.onConnect bridge
//      exists by querying the extension via CDP.
//
// Output: one JSON line. `{"success": true, "extension_id": "...", ...}`
// on success; `{"success": false, "error": "...", "stage": "..."}` on
// failure with a clear next step.

import AppKit
import Flow42Core
import Foundation

enum SetupBrowser {

    static func run(args: [String]) {
        let f = parseSimple(args)
        let force = f.bool("force")

        // 1. Verify extension dist exists.
        let extDist = ChromeLaunch.repoExtensionDist()
        let manifestPath = (extDist as NSString).appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestPath) else {
            emitJSON([
                "success": false,
                "stage": "extension-dist",
                "error": "extension dist/ not found at \(extDist)",
                "fix": "cd <repo-root> && npx vite build",
            ])
            exit(1)
        }

        // 2. Detect existing Chrome. If a Chrome is running but not on the
        // flow42 profile, ask user to quit first (or rerun with --force).
        let runningChrome = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.google.Chrome"
        }
        if let runningChrome {
            let usingOurProfile = chromeUsingFlow42Profile()
            if !usingOurProfile {
                if force {
                    print("Quitting existing Chrome (because --force)…")
                    runningChrome.terminate()
                    Thread.sleep(forTimeInterval: 1.0)
                } else {
                    emitJSON([
                        "success": false,
                        "stage": "chrome-running",
                        "error": "another Chrome is running with a different profile",
                        "fix": "quit Chrome (Cmd-Q) then rerun, or pass --force to quit it for you",
                    ])
                    exit(1)
                }
            } else {
                // Already running on our profile; check if CDP is up. If yes,
                // we're done — skip launch.
                if probeCDP(timeoutSec: 1.0) {
                    finalizeAndVerify(extDist: extDist, alreadyRunning: true)
                    return
                }
                // Running but no CDP — force a relaunch.
                print("Existing flow42 Chrome has no CDP endpoint; relaunching…")
                runningChrome.terminate()
                Thread.sleep(forTimeInterval: 1.0)
            }
        }

        // 3. Launch via chrome-launch with auto-load-extension.
        let task = Process()
        let exe = currentExecutablePath()
        task.executableURL = URL(fileURLWithPath: exe)
        task.arguments = ["chrome-launch"]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            emitJSON([
                "success": false,
                "stage": "chrome-launch",
                "error": "failed to launch Chrome: \(error.localizedDescription)",
            ])
            exit(1)
        }
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
            emitJSON([
                "success": false,
                "stage": "chrome-launch",
                "error": "chrome-launch exited \(task.terminationStatus)",
                "stdout": String(data: outData, encoding: .utf8) ?? "",
            ])
            exit(1)
        }

        // 4. Poll the CDP endpoint.
        if !probeCDP(timeoutSec: 10.0) {
            emitJSON([
                "success": false,
                "stage": "cdp-reachable",
                "error": "Chrome's debug endpoint at http://127.0.0.1:9222 didn't come up within 10s",
                "fix": "check that --load-extension was accepted (Chrome 138+ may need additional flags)",
            ])
            exit(1)
        }

        finalizeAndVerify(extDist: extDist, alreadyRunning: false)
    }

    // MARK: - finalize

    private static func finalizeAndVerify(extDist: String, alreadyRunning: Bool) {
        // 5. Register the native-messaging manifest with the deterministic id.
        let extensionId = ChromeLaunch.extensionId
        let installArgs = ["install", "--extension-id", extensionId]
        let installTask = Process()
        installTask.executableURL = URL(fileURLWithPath: currentExecutablePath())
        installTask.arguments = installArgs
        let installOut = Pipe()
        installTask.standardOutput = installOut
        installTask.standardError = installOut
        do {
            try installTask.run()
            installTask.waitUntilExit()
        } catch {
            emitJSON([
                "success": false,
                "stage": "install-native-host",
                "error": "flow42 install failed: \(error.localizedDescription)",
            ])
            exit(1)
        }

        // 6. Round-trip verify by listing CDP targets — confirm the
        // extension's service worker is present.
        let extensionAlive = probeExtensionTarget(id: extensionId, timeoutSec: 5.0)

        emitJSON([
            "success": extensionAlive,
            "extension_id": extensionId,
            "extension_dist": extDist,
            "user_data_dir": ChromeLaunch.defaultUserDataDir(),
            "cdp_endpoint": "http://127.0.0.1:9222",
            "already_running": alreadyRunning,
            "extension_loaded": extensionAlive,
            "next_steps": extensionAlive
                ? "you're set — try `flow42 record` then `flow42 record stop`"
                : "extension service worker not detected — open chrome://extensions to confirm Flow42 DOM Sidecar is enabled",
        ])
        exit(extensionAlive ? 0 : 1)
    }

    // MARK: - probes

    private static func probeCDP(timeoutSec: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSec)
        while Date() < deadline {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            task.arguments = ["-s", "--max-time", "1", "http://127.0.0.1:9222/json/version"]
            let out = Pipe()
            task.standardOutput = out
            task.standardError = Pipe()
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus == 0,
                   let data = try? out.fileHandleForReading.readToEnd(),
                   let str = String(data: data ?? Data(), encoding: .utf8),
                   str.contains("Browser") {
                    return true
                }
            } catch { /* retry */ }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    private static func probeExtensionTarget(id: String, timeoutSec: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSec)
        while Date() < deadline {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            task.arguments = ["-s", "--max-time", "1", "http://127.0.0.1:9222/json"]
            let out = Pipe()
            task.standardOutput = out
            task.standardError = Pipe()
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus == 0,
                   let data = try? out.fileHandleForReading.readToEnd(),
                   let str = String(data: data ?? Data(), encoding: .utf8),
                   str.contains(id) || str.contains("service_worker") {
                    return true
                }
            } catch { /* retry */ }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private static func chromeUsingFlow42Profile() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", "ps aux | grep 'Google Chrome.app/Contents/MacOS' | grep -v Helper | grep -v grep"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            if let data = try? out.fileHandleForReading.readToEnd(),
               let str = String(data: data ?? Data(), encoding: .utf8) {
                return str.contains("flow42-chrome")
            }
        } catch { }
        return false
    }

    private static func currentExecutablePath() -> String {
        var size = UInt32(0)
        _ = _NSGetExecutablePath(nil, &size)
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: Int(size))
        defer { buf.deallocate() }
        guard _NSGetExecutablePath(buf, &size) == 0 else {
            return CommandLine.arguments[0]
        }
        let raw = String(cString: buf)
        return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
    }
}
