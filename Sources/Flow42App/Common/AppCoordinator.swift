// AppCoordinator.swift - Lightweight shared state for cross-cut UI
// concerns that don't fit inside any single SwiftUI view's local state.
//
// Today: holds the deep-link request from Flow42Menu (a flow directory
// path the user clicked elsewhere). AppShell observes the latest value;
// when it changes, AppShell switches the active project to whichever
// project owns that directory and pushes a FlowDetailView onto the
// navigation stack.

import Combine
import Flow42Core
import Foundation

@MainActor
final class AppCoordinator: ObservableObject {

    /// Most recent "open this flow directory" request. Bumped whenever
    /// a deep-link notification arrives from Flow42Menu (or anywhere
    /// else that wants to point the main window at a specific flow).
    /// Resets to nil after the navigation stack acts on it so the
    /// onChange observer fires again on every fresh request.
    @Published var pendingOpenFlowDir: String?

    /// "Open this fresh recording" request. The directory has only
    /// `events.jsonl` + `steps/` — no `flow.yaml` — so the main app
    /// pushes a RecordingHandoffView that immediately runs the
    /// flow-creator skill in a chat. Carries the recording dir + slug
    /// so the chat prompt can name both.
    struct PendingRecording: Equatable {
        let dir: String
        let slug: String
    }
    @Published var pendingOpenRecording: PendingRecording?

    init() {
        // DistributedNotificationCenter delivers on the main run loop
        // for the current thread; we explicitly hop to MainActor inside
        // the closure since the API is not actor-aware.
        DistributedNotificationCenter.default().addObserver(
            forName: Flow42DeepLink.openFlowNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let dir = note.userInfo?[Flow42DeepLink.flowDirKey] as? String
            guard let dir, !dir.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.pendingOpenFlowDir = dir
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Flow42DeepLink.openRecordingNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let dir = note.userInfo?[Flow42DeepLink.recordingDirKey] as? String
            let slug = note.userInfo?[Flow42DeepLink.recordingSlugKey] as? String
            FileHandle.standardError.write(Data(
                "[Flow42App] deep-link received: dir=\(dir ?? "nil") slug=\(slug ?? "nil")\n".utf8
            ))
            guard let dir, !dir.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.pendingOpenRecording = PendingRecording(
                    dir: dir, slug: slug ?? ""
                )
            }
        }
    }
}
