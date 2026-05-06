// Find.swift - `flow42 find` CLI command.
//
// Search for elements by name / role / DOM id / DOM class / identifier
// across the UI, filtered like Ghost OS's flow42_find. At least one search
// parameter is required.

import Flow42Core
import Foundation

enum Find {
    static func run(args: [String]) {
        let f = parseSimple(args)
        if f.string("target") == "browser" {
            BrowserDriver.dispatch(verb: "find", flags: f)
            return
        }
        let result = Perception.findElements(
            query: f.string("query"),
            role: f.string("role"),
            domId: f.string("dom-id"),
            domClass: f.string("dom-class"),
            identifier: f.string("identifier"),
            appName: f.string("app"),
            depth: f.int("depth")
        )
        emitToolResult(result)
    }
}
