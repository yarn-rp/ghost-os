// Snapshot.swift - `flow42 snapshot` CLI command.
//
// Two paths share one verb:
//   native (default)  — current frontmost window via ScreenCaptureKit.
//   browser           — current page in the running Chrome attach.
//
// Output:
//   --output PATH    write raw JPEG/PNG bytes to PATH; print metadata JSON.
//   (no --output)    write JSON {success, image: base64, width, height, …} to stdout.

import Flow42Core
import Foundation

enum Snapshot {

    static func run(args: [String]) {
        let f = parseSimple(args)
        if f.string("target") == "browser" || f.string("locator") != nil || f.string("tab") != nil {
            BrowserDriver.dispatch(verb: "snapshot", flags: f)
            return
        }

        let appName = f.string("app")
        let fullRes = f.bool("full-resolution")
        let result = Perception.screenshot(appName: appName, fullResolution: fullRes)
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
                writeJSONLine(meta)
            } catch {
                emitJSON(["success": false, "error": "write failed: \(error.localizedDescription)"])
                exit(1)
            }
            return
        }
        var payload = data
        payload["success"] = true
        writeJSONLine(payload)
    }
}
