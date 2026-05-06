// Flow42DeepLink.swift - Cross-process "open this flow in the main app"
// channel.
//
// Posted by Flow42Menu when a recording row is clicked; observed by
// Flow42App's delegate which routes to the matching project + pushes
// the FlowDetailView. Uses DistributedNotificationCenter so it works
// without inventing a URL scheme bundle plist (dev builds don't have
// one) and doesn't require either app to be a launch-services target.
//
// Payload contract:
//   userInfo["flow_dir"] = absolute path to the recording directory.
//
// If the main app isn't running yet, the notification is dropped — the
// caller should launch the binary first or rely on the user opening
// Flow42 themselves.

import Foundation

public nonisolated enum Flow42DeepLink {
    /// "Open this flow" — the flow already has a `flow.yaml`, so the
    /// main app pushes a regular FlowDetailView. Posted by the menu
    /// app when the user clicks a recording row.
    public static let openFlowNotification = Notification.Name("com.web42.flow42.open-flow")
    public static let flowDirKey = "flow_dir"

    /// "Open this recording" — the directory has only `events.jsonl`
    /// + `steps/`, NO `flow.yaml` yet. Posted by the menu app the
    /// moment `record stop` returns success so the main app can spin
    /// up an autonomous chat that runs the flow-creator skill against
    /// the fresh capture.
    public static let openRecordingNotification = Notification.Name("com.web42.flow42.open-recording")
    public static let recordingDirKey = "recording_dir"
    public static let recordingSlugKey = "recording_slug"

    /// Fire-and-forget. Posts a distributed notification so any running
    /// Flow42App instance can pick up the request and navigate.
    public static func postOpenFlow(dir: String) {
        DistributedNotificationCenter.default().postNotificationName(
            openFlowNotification,
            object: nil,
            userInfo: [flowDirKey: dir],
            deliverImmediately: true
        )
    }

    /// Companion to `postOpenFlow` for fresh recordings. The main app
    /// listens, switches to the owning project, and pushes the
    /// recording-handoff chat surface.
    public static func postOpenRecording(dir: String, slug: String) {
        DistributedNotificationCenter.default().postNotificationName(
            openRecordingNotification,
            object: nil,
            userInfo: [
                recordingDirKey: dir,
                recordingSlugKey: slug,
            ],
            deliverImmediately: true
        )
    }
}
