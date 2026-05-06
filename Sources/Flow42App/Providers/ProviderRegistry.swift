// ProviderRegistry.swift - The catalogue of AI providers Flow42App can drive.
//
// v1 ships a single entry: Claude Code (via Zed's claude-code-acp adapter).
// The registry is structured as an array so adding the next provider is a
// 5-line change; no other code in the app special-cases "claude".
//
// Why model providers as `(adapter, args)` rather than just "the CLI":
// most coding agents don't speak ACP natively yet. Claude Code uses
// `@zed-industries/claude-code-acp` as a bridge. So a provider is the
// _adapter command_, not the bare CLI underneath it.

import Foundation

/// Stable description of one AI provider — what to spawn, how to identify
/// auth/install failures, what to tell the user when something's wrong.
struct ProviderDefinition: Identifiable, Hashable {
    /// Stable id used in config.yaml. Never user-visible.
    let id: String

    /// Display name shown in Settings.
    let displayName: String

    /// SF Symbol shown next to the name in Settings.
    let logoSymbol: String

    /// One-line tagline shown under the name.
    let tagline: String

    /// How to spawn the ACP adapter for this provider.
    let launch: LaunchSpec

    /// What to tell the user if `initialize` returns auth-required.
    let authHint: String

    /// What to tell the user if the launch executable can't be found.
    let installHint: String

    /// Human-readable URL the user can open for setup help.
    let docsURL: URL?

    var id_: String { id }  // for older Identifiable inference
}

struct LaunchSpec: Hashable {
    /// Command to invoke. May be a bare name (resolved against PATH) or
    /// an absolute path.
    let executable: String
    /// Argument vector. Does NOT include the executable name.
    let args: [String]
    /// Additive environment overrides. Merged on top of the inherited env.
    let env: [String: String]

    init(executable: String, args: [String] = [], env: [String: String] = [:]) {
        self.executable = executable
        self.args = args
        self.env = env
    }
}

enum ProviderRegistry {

    /// All known providers. v1 = Claude Code only. Adding a second entry
    /// here makes a second card appear in Settings without other code
    /// changes — that's the abstraction's whole point.
    static let all: [ProviderDefinition] = [
        ProviderDefinition(
            id: "claude",
            displayName: "Claude Code",
            logoSymbol: "sparkles",
            tagline: "Anthropic's coding agent. Drives flows via the official ACP adapter.",
            launch: LaunchSpec(
                executable: "npx",
                args: ["-y", "@agentclientprotocol/claude-agent-acp"],
                // Pin to Haiku 4.5: cheaper + faster than Sonnet for the
                // tight flow42-do/play loop the agent runs. Read by the
                // Claude Agent SDK that the adapter wraps. If we ever
                // expose a model picker in Settings, this becomes the
                // default and the user override flows through the same
                // env mechanism.
                env: ["ANTHROPIC_MODEL": "claude-haiku-4-5"]
            ),
            authHint: "Run `claude login` in your terminal, then try again.",
            installHint: "Install the adapter:  npm i -g @agentclientprotocol/claude-agent-acp",
            docsURL: URL(string: "https://github.com/agentclientprotocol/claude-agent-acp")
        ),
    ]

    /// Look up a provider by its config.yaml id. Returns nil for unknown
    /// ids (config drift after a registry change, etc.).
    static func find(id: String) -> ProviderDefinition? {
        all.first { $0.id == id }
    }

    /// The default selected provider on first run / when config.yaml is
    /// absent. Today this is Claude Code — the only option.
    static var defaultProvider: ProviderDefinition? {
        all.first
    }
}
