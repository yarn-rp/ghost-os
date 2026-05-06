// AutonomousRunChatPanel.swift / AutonomousRunRoute.swift - Empty-
// state landing route for the case where someone navigates here but
// the chat actually lives elsewhere now.
//
// Pre-per-session-chat, this route hosted a global Flow42ChatView
// bound to ~/.flow42/agent-latest.json. With per-recording sessions
// every chat is rooted in a recording or flow directory, so this
// destination is reachable only via legacy deep-links — it now
// nudges the user back to a flow / recording surface.

import Flow42Core
import SwiftUI

struct AutonomousRunRoute: View {
    @EnvironmentObject private var router: DetailRouter

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.tertiary)
            Text("No active conversation")
                .font(.system(size: DT.f15, weight: .semibold))
            Text("Open a recording from the sidebar to view its chat with flow-creator.")
                .font(.system(size: DT.f12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button { router.pop() } label: {
                Text("Back to flows")
                    .font(.system(size: DT.f12, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
