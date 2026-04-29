// Install.swift - `flow42 install` CLI subcommand
//
// Writes Chrome's native-messaging manifest at the OS-correct location so
// the browser can launch `flow42 native-host` when the extension calls
// chrome.runtime.connectNative('com.web42.flow42').
//
// Manifest paths follow Chrome's per-OS conventions:
//   macOS:   ~/Library/Application Support/Google/Chrome/NativeMessagingHosts/<host>.json
//   Linux:   ~/.config/google-chrome/NativeMessagingHosts/<host>.json
//   Windows: HKCU\Software\Google\Chrome\NativeMessagingHosts\<host> (registry)
//
// The manifest's `path` field points directly at the running flow42 binary —
// no shim needed since Swift binaries don't depend on a Node runtime that
// Chrome's stripped PATH might not find.

import Foundation

enum Install {

    static let hostName = "com.web42.flow42"

    static func run(args: [String]) {
        guard let extensionId = parseFlag(args, "--extension-id", "-e"), !extensionId.isEmpty else {
            fputs("error: --extension-id is required\n", stderr)
            fputs("       find it on chrome://extensions (toggle Developer mode).\n", stderr)
            exit(1)
        }

        let outDir = parseFlag(args, "--out", "-o")
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? defaultManifestDir()

        let binaryPath = resolveBinaryPath()

        let manifest: [String: Any] = [
            "name": hostName,
            "description": "flow42 native host for the Web-Flow Chrome extension",
            "path": binaryPath,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionId)/"],
        ]

        do {
            try FileManager.default.createDirectory(
                at: outDir,
                withIntermediateDirectories: true
            )
        } catch {
            fputs("error: failed to create \(outDir.path): \(error)\n", stderr)
            exit(1)
        }

        let manifestPath = outDir.appendingPathComponent("\(hostName).json")
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: manifest,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            fputs("error: failed to serialise manifest: \(error)\n", stderr)
            exit(1)
        }

        do {
            try data.write(to: manifestPath)
        } catch {
            fputs("error: failed to write \(manifestPath.path): \(error)\n", stderr)
            exit(1)
        }

        print("Installed native-messaging manifest: \(manifestPath.path)")
        print("Host binary:    \(binaryPath)")
        print("Allowed origin: chrome-extension://\(extensionId)/")

        #if os(Windows)
        print("")
        print("Windows: also import the manifest into the registry:")
        print("  reg add \"HKCU\\Software\\Google\\Chrome\\NativeMessagingHosts\\\(hostName)\" /ve /t REG_SZ /d \"\(manifestPath.path)\" /f")
        #endif
    }

    // MARK: - Helpers

    private static func defaultManifestDir() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS)
        return home
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Google")
            .appendingPathComponent("Chrome")
            .appendingPathComponent("NativeMessagingHosts")
        #elseif os(Linux)
        return home
            .appendingPathComponent(".config")
            .appendingPathComponent("google-chrome")
            .appendingPathComponent("NativeMessagingHosts")
        #else
        return home
            .appendingPathComponent(".config")
            .appendingPathComponent("flow42")
            .appendingPathComponent("NativeMessagingHosts")
        #endif
    }

    /// Resolve the absolute path of the running `flow42` binary so the
    /// manifest points at exactly the binary the user is invoking from.
    private static func resolveBinaryPath() -> String {
        // CommandLine.arguments[0] is the program name as invoked. If it's
        // a relative path, resolve against CWD; if it's bare `flow42`, fall
        // back to which-style PATH lookup. realpath() resolves any symlinks.
        let argv0 = CommandLine.arguments.first ?? "flow42"
        let resolved: String
        if argv0.hasPrefix("/") {
            resolved = argv0
        } else if argv0.contains("/") {
            let cwd = FileManager.default.currentDirectoryPath
            resolved = (cwd as NSString).appendingPathComponent(argv0)
        } else {
            // Bare command name — search PATH.
            resolved = whichPath(for: argv0) ?? argv0
        }
        // Resolve symlinks. Chrome dislikes symlinks in the manifest path.
        return URL(fileURLWithPath: resolved).resolvingSymlinksInPath().path
    }

    private static func whichPath(for cmd: String) -> String? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in path.split(separator: ":") {
            let candidate = (String(dir) as NSString).appendingPathComponent(cmd)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func parseFlag(_ args: [String], _ long: String, _ short: String) -> String? {
        var i = 0
        while i < args.count {
            if args[i] == long || args[i] == short {
                if i + 1 < args.count { return args[i + 1] }
                return nil
            }
            i += 1
        }
        return nil
    }
}
