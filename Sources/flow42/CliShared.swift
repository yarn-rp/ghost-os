// CliShared.swift - Helpers shared across flow42 subcommands.
//
// Flag parsing, JSON output, and the dispatch shim that spawns the
// browser-driver subprocess for browser-target verbs.

import Flow42Core
import Foundation

// MARK: - Flag parsing

struct CliFlags {
    let map: [String: String]
    let bools: Set<String>

    func string(_ name: String) -> String? { map[name] }
    func int(_ name: String) -> Int? { map[name].flatMap(Int.init) }
    func double(_ name: String) -> Double? { map[name].flatMap(Double.init) }
    func bool(_ name: String) -> Bool { bools.contains(name) }
    func list(_ name: String) -> [String] {
        guard let v = map[name] else { return [] }
        return v.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    }
}

func parseSimple(_ args: [String]) -> CliFlags {
    var map: [String: String] = [:]
    var bools: Set<String> = []
    var i = 0
    while i < args.count {
        let a = args[i]
        guard a.hasPrefix("--") else { i += 1; continue }
        let key = String(a.dropFirst(2))
        if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
            map[key] = args[i + 1]
            i += 2
        } else {
            bools.insert(key)
            i += 1
        }
    }
    return CliFlags(map: map, bools: bools)
}

// MARK: - Output

func emitJSON(_ dict: [String: Any]) {
    if let data = try? JSONSerialization.data(
        withJSONObject: dict,
        options: [.withoutEscapingSlashes]
    ),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

func writeJSONLine(_ dict: [String: Any]) {
    emitJSON(dict)
}

func emitError(_ result: ToolResult) {
    var dict: [String: Any] = ["success": false]
    if let err = result.error { dict["error"] = err }
    if let sug = result.suggestion { dict["suggestion"] = sug }
    emitJSON(dict)
}

/// Standard CLI emit for a ToolResult. Flattens success.data into the top
/// level so callers don't have to drill into a `data:` field. Exits 1 on
/// failure.
func emitToolResult(_ result: ToolResult) {
    if !result.success {
        emitError(result)
        exit(1)
    }
    var payload: [String: Any] = ["success": true]
    if let data = result.data { payload.merge(data) { _, new in new } }
    emitJSON(payload)
}

// MARK: - Browser-driver dispatch

enum BrowserDriver {

    /// Spawn the browser-driver subprocess for the given verb, forwarding the
    /// flags it accepts. Pipes the driver's last JSON line to stdout.
    static func dispatch(verb: String, flags: CliFlags) {
        let driverPath = browserDriverPath()
        guard FileManager.default.isReadableFile(atPath: driverPath) else {
            emitJSON([
                "success": false,
                "error": "browser driver not found at \(driverPath)",
                "suggestion": "set FLOW42_BROWSER_DRIVER to the path of run.mjs, or run flow42 from the project tree.",
            ])
            exit(1)
        }

        var argv = ["node", driverPath, verb]
        let stringFlags = [
            "locator", "to-locator", "text", "button", "count", "key",
            "modifiers", "direction", "amount", "url", "tab", "output",
            "full-resolution", "query", "role", "dom-id", "dom-class",
            "identifier", "depth", "max-labels", "condition", "value",
            "timeout", "interval", "duration",
            "from-x", "from-y", "to-x", "to-y", "x", "y",
        ]
        for name in stringFlags {
            if let v = flags.string(name) {
                argv.append("--\(name)")
                argv.append(v)
            }
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = argv

        // Forward our own absolute path so the driver can re-invoke
        // `chrome-launch` if the dedicated CDP endpoint isn't up yet —
        // that's what lets the user record on their regular Chrome while
        // agent actions auto-launch the dedicated profile on demand.
        var env = ProcessInfo.processInfo.environment
        env["FLOW42_BINARY"] = currentBinaryPath()
        task.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        do {
            try task.run()
        } catch {
            emitJSON([
                "success": false,
                "error": "could not invoke browser driver: \(error.localizedDescription)",
            ])
            exit(1)
        }
        task.waitUntilExit()

        let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let lastLine = outStr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? ""
        if !lastLine.isEmpty {
            print(lastLine)
        } else {
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            emitJSON([
                "success": false,
                "error": "browser driver produced no output",
                "stderr": String(errStr.prefix(500)),
            ])
        }
        if task.terminationStatus != 0 { exit(task.terminationStatus) }
    }

    /// Absolute path of the running flow42 binary (resolved through symlinks)
    /// so we can pass it to the browser driver for `chrome-launch` re-invocation.
    private static func currentBinaryPath() -> String {
        var size = UInt32(0)
        _ = _NSGetExecutablePath(nil, &size)
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: Int(size))
        defer { buf.deallocate() }
        guard _NSGetExecutablePath(buf, &size) == 0 else {
            return CommandLine.arguments[0]
        }
        return URL(fileURLWithPath: String(cString: buf))
            .resolvingSymlinksInPath().path
    }

    static func browserDriverPath() -> String {
        if let env = ProcessInfo.processInfo.environment["FLOW42_BROWSER_DRIVER"] {
            return env
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir
                .deletingLastPathComponent()
                .appendingPathComponent("runtime")
                .appendingPathComponent("browser-driver")
                .appendingPathComponent("run.mjs")
            if FileManager.default.isReadableFile(atPath: candidate.path) {
                return candidate.path
            }
            let candidate2 = dir
                .appendingPathComponent("runtime")
                .appendingPathComponent("browser-driver")
                .appendingPathComponent("run.mjs")
            if FileManager.default.isReadableFile(atPath: candidate2.path) {
                return candidate2.path
            }
            dir = dir.deletingLastPathComponent()
        }
        return "/opt/openclaw/flow42/runtime/browser-driver/run.mjs"
    }
}
