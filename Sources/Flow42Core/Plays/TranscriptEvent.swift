// TranscriptEvent.swift - One line of an agent's chat as both apps render
// it. Coarser than the underlying ACP message model — multi-block agent
// turns collapse into one assistant text line, and tool calls + results
// each get their own entry.
//
// Lives in Flow42Core because BOTH apps traffic in these:
//
//   - Flow42App produces them from ACPClient (the agent subprocess) and
//     persists them via AgentLatestFile + AgentTranscriptLog.
//   - Flow42Menu reads them back via AgentLatestClient and renders the
//     compact bubble + chat-mode transcript inside the floating panel.
//
// Codable so the cross-process JSON pipe works end-to-end with no manual
// schema mapping.

import Foundation

public nonisolated struct TranscriptEvent: Identifiable, Equatable, Codable, Sendable {

    public nonisolated enum Kind: Equatable, Codable, Sendable {
        case systemInfo(String)        // session id, init, etc.
        case assistantText(String)
        case toolCall(name: String, summary: String)
        case toolResult(summary: String, isError: Bool)
        case userMessage(String)       // initial prompt + any follow-ups
        case finalResult(text: String, durationMs: Int?, totalCostUSD: Double?)
        case error(String)
        case raw(String)               // catch-all for unrecognised shapes
    }

    public let id: UUID
    public let kind: Kind
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
    }
}
