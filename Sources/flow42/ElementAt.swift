// ElementAt.swift - `flow42 element-at --x N --y N` CLI command.
//
// Identify whatever element is at the given screen coordinate. Useful for
// converting screenshot pixel coordinates back into a locator the agent
// can pass to flow42 act.

import Flow42Core
import Foundation

enum ElementAt {
    static func run(args: [String]) {
        let f = parseSimple(args)
        if f.string("target") == "browser" {
            BrowserDriver.dispatch(verb: "element-at", flags: f)
            return
        }
        guard let x = f.double("x"), let y = f.double("y") else {
            emitJSON(["success": false, "error": "element-at requires --x and --y"])
            exit(2)
        }
        let result = Perception.elementAt(x: x, y: y)
        emitToolResult(result)
    }
}
