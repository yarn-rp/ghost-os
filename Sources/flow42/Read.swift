// Read.swift - `flow42 read` CLI command.
//
// Extract text content from any app. With --query, narrows to a specific
// element subtree. --depth controls how deep to walk for nested content.

import Flow42Core
import Foundation

enum Read {
    static func run(args: [String]) {
        let f = parseSimple(args)
        if f.string("target") == "browser" {
            BrowserDriver.dispatch(verb: "read", flags: f)
            return
        }
        let result = Perception.readContent(
            appName: f.string("app"),
            query: f.string("query"),
            depth: f.int("depth")
        )
        emitToolResult(result)
    }
}
