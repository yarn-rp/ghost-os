// ReplicateCommand.swift - Build the deterministic CLI invocation that
// reproduces a recorded action.
//
// Output is dual-form: a POSIX-shell-safe string (for skill.md, logs, copy
// & paste) and an argv array (for direct exec without going through /bin/sh).
//
// This runs at capture time as part of `LearningDispatch.serializeAction`,
// so every action in flow.json carries its own replay command. No model in
// the loop, no field-to-flag mapping at runtime — the recording is its own
// instruction set.

import Foundation

nonisolated public enum ReplicateCommand {

    public struct Built: Sendable {
        public let shellString: String
        public let argv: [String]
    }

    /// Build the replicate command for a native action.
    public static func native(_ action: ObservedAction) -> Built? {
        let app = action.appName.isEmpty ? nil : action.appName
        switch action.action {
        case .click(let x, let y, let button, let count):
            var argv = ["act", "click",
                        "--x", trim(x),
                        "--y", trim(y),
                        "--button", button,
                        "--count", String(count)]
            if let app { argv += ["--app", app] }
            return Built(shellString: shellJoin(argv), argv: argv)

        case .typeText(let text):
            var argv = ["act", "type", "--text", text]
            if let app { argv += ["--app", app] }
            return Built(shellString: shellJoin(argv), argv: argv)

        case .keyPress(_, let keyName, let modifiers):
            var argv = ["act", "press", "--key", keyName]
            if !modifiers.isEmpty { argv += ["--modifiers", modifiers.joined(separator: ",")] }
            if let app { argv += ["--app", app] }
            return Built(shellString: shellJoin(argv), argv: argv)

        case .hotkey(let modifiers, let keyName):
            let combo = (modifiers + [keyName]).joined(separator: ",")
            var argv = ["act", "hotkey", "--keys", combo]
            if let app { argv += ["--app", app] }
            return Built(shellString: shellJoin(argv), argv: argv)

        case .scroll(let dx, let dy, let x, let y):
            let direction: String
            let amount: Int
            if abs(dy) >= abs(dx) {
                direction = dy > 0 ? "up" : "down"
                amount = abs(dy)
            } else {
                direction = dx > 0 ? "left" : "right"
                amount = abs(dx)
            }
            var argv = ["act", "scroll",
                        "--direction", direction,
                        "--amount", String(max(1, amount)),
                        "--x", trim(x), "--y", trim(y)]
            if let app { argv += ["--app", app] }
            return Built(shellString: shellJoin(argv), argv: argv)

        case .appSwitch(_, let toBundleId):
            // Prefer bundle id when present; falls back to app name otherwise.
            let target: String
            if !toBundleId.isEmpty {
                target = toBundleId
            } else if case .appSwitch(let toApp, _) = action.action {
                target = toApp
            } else {
                return nil
            }
            let argv = ["act", "app-switch", "--to", target]
            return Built(shellString: shellJoin(argv), argv: argv)

        case .secureField, .narration:
            // Sensitive / informational: no replay command.
            return nil

        case .urlChange(let url):
            // Replay any URL change via the navigate verb. The agent gets
            // a clean "go to this URL" action regardless of how the user
            // originally got there (typed address, link click, redirect).
            let argv = ["act", "navigate", "--url", url]
            return Built(shellString: shellJoin(argv), argv: argv)

        case .newTab(let url):
            // Open a new tab via Cmd+T then navigate. Two-step replay
            // captured as a single argv string so the agent doesn't have
            // to model "tab management" semantics.
            let argv = ["act", "navigate", "--url", url, "--new-tab"]
            return Built(shellString: shellJoin(argv), argv: argv)

        case .tabSwitch:
            // Tab switching has no canonical replay primitive yet — the
            // agent reasons about which tab to be on based on URL/title
            // state. We emit the event for visibility but no replicate.
            return nil
        }
    }

    // MARK: - Shell quoting

    /// POSIX single-quoted form. Embedded single quotes become `'\''`.
    public static func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        if s.allSatisfy(isShellSafe) { return s }
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    public static func shellJoin(_ argv: [String]) -> String {
        // Prefix the binary so the string is runnable as-is.
        return (["flow42"] + argv).map(shellQuote).joined(separator: " ")
    }

    private static func isShellSafe(_ c: Character) -> Bool {
        return c.isLetter || c.isNumber || "_-./:=,+@".contains(c)
    }

    /// Trim trailing zeros from a Double so coordinates render as `1327` or
    /// `1167.25` rather than `1327.0` or `1167.250000`.
    private static func trim(_ d: Double) -> String {
        if d == d.rounded() { return String(Int(d.rounded())) }
        return String(format: "%g", d)
    }
}
