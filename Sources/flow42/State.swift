// State.swift - `flow42 state` CLI command.
//
// Lists every running app with windows, positions, and sizes (or just the
// named app via --app). Native: Perception.getState. Browser: list of
// contexts/pages from the running browser attach.

import Flow42Core
import Foundation

enum State {
    static func run(args: [String]) {
        let f = parseSimple(args)
        if f.string("target") == "browser" {
            BrowserDriver.dispatch(verb: "state", flags: f)
            return
        }
        let result = Perception.getState(appName: f.string("app"))
        emitToolResult(result)
    }
}
