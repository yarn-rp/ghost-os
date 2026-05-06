// Inspect.swift - `flow42 inspect` CLI command.
//
// Get complete metadata for one element: role, position, actions, DOM id,
// editable state, etc. Pass --query OR --dom-id; optionally --role + --app
// to disambiguate.

import Flow42Core
import Foundation

enum Inspect {
    static func run(args: [String]) {
        let f = parseSimple(args)
        if f.string("target") == "browser" {
            BrowserDriver.dispatch(verb: "inspect", flags: f)
            return
        }
        guard let query = f.string("query") else {
            // Allow inspect by domId without --query.
            if f.string("dom-id") == nil {
                emitJSON(["success": false, "error": "inspect requires --query or --dom-id"])
                exit(2)
            }
            let result = Perception.inspect(
                query: "",
                role: f.string("role"),
                domId: f.string("dom-id"),
                appName: f.string("app")
            )
            emitToolResult(result)
            return
        }
        let result = Perception.inspect(
            query: query,
            role: f.string("role"),
            domId: f.string("dom-id"),
            appName: f.string("app")
        )
        emitToolResult(result)
    }
}
