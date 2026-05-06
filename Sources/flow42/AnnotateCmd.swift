// AnnotateCmd.swift - `flow42 annotate` CLI command.
//
// Set-of-Marks annotated screenshot: numbered labels overlaid on every
// interactive element, plus a JSON map of label → element. Useful when an
// agent wants to ask the user "what number is the right button?" or to
// hand a vision model a clean target list.

import Flow42Core
import Foundation

enum AnnotateCmd {
    static func run(args: [String]) {
        let f = parseSimple(args)
        if f.string("target") == "browser" {
            BrowserDriver.dispatch(verb: "annotate", flags: f)
            return
        }
        let roles = f.list("roles").isEmpty ? nil : f.list("roles")
        let result = Annotate.annotate(
            appName: f.string("app"),
            roles: roles,
            maxLabels: f.int("max-labels")
        )
        guard result.success, let data = result.data else {
            emitError(result)
            exit(1)
        }
        if let outputPath = f.string("output"),
           let b64 = data["image"] as? String,
           let bytes = Data(base64Encoded: b64) {
            do {
                try bytes.write(to: URL(fileURLWithPath: outputPath))
                var meta = data
                meta.removeValue(forKey: "image")
                meta["output"] = outputPath
                meta["success"] = true
                emitJSON(meta)
            } catch {
                emitJSON(["success": false, "error": "write failed: \(error.localizedDescription)"])
                exit(1)
            }
            return
        }
        var payload = data
        payload["success"] = true
        emitJSON(payload)
    }
}
