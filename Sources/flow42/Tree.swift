// Tree.swift - `flow42 tree` CLI command.
//
// Dump the accessibility hierarchy of the current screen (frontmost app or
// named via --app) — same data Ghost OS's MCP `flow42_context` returns,
// reachable from the shell so an agent disambiguating a step doesn't have
// to spin up an MCP session just to look at the AX tree.
//
// Browser target reaches into the running Chrome's active page and returns
// the page's accessibility tree (Playwright `page.accessibility.snapshot()`).
//
// Output: one JSON line on stdout. With --output, writes the JSON to that
// file and prints {success, output} on stdout.

import Flow42Core
import Foundation

enum Tree {

    static func run(args: [String]) {
        let f = parseSimple(args)
        if f.string("target") == "browser" || f.string("locator") != nil || f.string("tab") != nil {
            BrowserDriver.dispatch(verb: "tree", flags: f)
            return
        }

        let result = Perception.getContext(appName: f.string("app"))
        guard result.success else {
            emitError(result)
            exit(1)
        }
        var payload: [String: Any] = ["success": true]
        if let data = result.data { payload.merge(data) { _, new in new } }

        if let outputPath = f.string("output") {
            do {
                let json = try JSONSerialization.data(
                    withJSONObject: payload,
                    options: [.prettyPrinted, .withoutEscapingSlashes]
                )
                try json.write(to: URL(fileURLWithPath: outputPath))
                writeJSONLine(["success": true, "output": outputPath, "bytes": json.count])
            } catch {
                emitJSON(["success": false, "error": "write failed: \(error.localizedDescription)"])
                exit(1)
            }
            return
        }
        writeJSONLine(payload)
    }
}
