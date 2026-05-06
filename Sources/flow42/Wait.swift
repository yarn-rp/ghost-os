// Wait.swift - `flow42 wait` CLI command.
//
// Polls for a condition with a timeout. Replaces brittle fixed sleeps in
// skill steps. Conditions match Ghost OS's WaitManager:
//   urlContains, urlEquals, urlChanged
//   titleContains, titleEquals, titleChanged
//   elementExists, elementGone

import Flow42Core
import Foundation

enum Wait {
    static func run(args: [String]) {
        let f = parseSimple(args)
        if f.string("target") == "browser" {
            BrowserDriver.dispatch(verb: "wait", flags: f)
            return
        }
        guard let condition = f.string("condition") else {
            emitJSON([
                "success": false,
                "error": "wait requires --condition (urlContains | urlEquals | urlChanged | titleContains | titleEquals | titleChanged | elementExists | elementGone)",
            ])
            exit(2)
        }
        let timeout = f.double("timeout") ?? 10.0
        let interval = f.double("interval") ?? 0.25
        let result = WaitManager.waitFor(
            condition: condition,
            value: f.string("value"),
            appName: f.string("app"),
            timeout: timeout,
            interval: interval
        )
        emitToolResult(result)
    }
}
