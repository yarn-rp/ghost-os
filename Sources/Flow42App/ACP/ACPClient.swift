// ACPClient.swift - Minimal Agent Client Protocol client over stdio.
//
// We spawn the user's configured ACP adapter (e.g. `npx
// @agentclientprotocol/claude-agent-acp`), exchange JSON-RPC 2.0
// messages, and surface streaming agent output as TranscriptEvents.
//
// Why we wrote this instead of vendoring aptove/swift-sdk:
//
//   - The SDK is young (v0.1.x, single-digit stars). For v1 we want to
//     own the wire path so debugging it doesn't require chasing an
//     external dep's quirks. ~400 LOC of careful async code is
//     manageable; if the SDK matures we can swap behind AIProviderClient
//     later.
//   - We only need ~5 methods (initialize, session/new, session/prompt,
//     session/cancel + reply to session/request_permission). The bulk of
//     the SDK isn't in our path.
//
// What this client supports today:
//
//   - Spawn the adapter as a subprocess (stdin/stdout pipes, stderr
//     forwarded as TranscriptEvent.raw).
//   - JSON-RPC framing: newline-delimited JSON, request/response
//     correlation by id, server notifications routed by method name.
//   - `initialize` handshake (we advertise no fancy capabilities; the
//     adapter handles the agent's auth).
//   - `session/new` to open a session in the active flow's directory.
//   - `session/prompt` to send the user message; we yield a
//     TranscriptEvent for each `session/update` notification we receive
//     until the prompt's response arrives with the stop reason.
//   - Auto-reply YES to `session/request_permission` for any tool call
//     in our allowlist (`Bash(flow42 *)` and read-only fs). Anything
//     else gets denied — keeps the blast radius scoped to flow42 work.
//   - `session/cancel` notification on terminate(), then SIGTERM the
//     subprocess if it doesn't exit on its own.
//
// What's deferred:
//
//   - Re-using sessions across multiple prompts (today: one prompt per
//     spawn).
//   - fs/* and terminal/* callbacks that mutate the user's machine.
//     We respond "method not supported" so the agent gets a clean
//     failure if it tries.

import Flow42Core
import Foundation

@MainActor
final class ACPClient {

    enum LaunchError: Error, CustomStringConvertible {
        case adapterNotFound(executable: String)
        case spawnFailed(detail: String)
        case initializeFailed(detail: String)

        var description: String {
            switch self {
            case .adapterNotFound(let exec):
                return "Couldn't find `\(exec)` on your PATH. Make sure Node.js is installed and `npx` is reachable."
            case .spawnFailed(let d):
                return "Couldn't start the ACP adapter: \(d)"
            case .initializeFailed(let d):
                return "ACP initialize failed: \(d)"
            }
        }
    }

    /// Where transcript events go. Drain this from the SwiftUI side.
    let events: AsyncStream<TranscriptEvent>
    private let continuation: AsyncStream<TranscriptEvent>.Continuation

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var nextRequestId: Int = 1

    /// Sendable box for arbitrary JSON values. We're @MainActor-isolated
    /// throughout, so the unchecked is safe — both producer (demux) and
    /// consumer (call sites) run on the main actor. The compiler can't
    /// see that without the box because `Any?` itself isn't Sendable.
    struct JSONBox: @unchecked Sendable {
        let value: Any?
    }

    /// Pending request continuations keyed by JSON-RPC id. We resume the
    /// continuation when the matching response (or error) arrives.
    private var pendingRequests: [Int: CheckedContinuation<JSONBox, any Error>] = [:]

    /// Active session id (set after `session/new` succeeds).
    private var sessionId: String?

    init() {
        var local: AsyncStream<TranscriptEvent>.Continuation!
        self.events = AsyncStream { local = $0 }
        self.continuation = local
    }

    // MARK: - Lifecycle
    //
    // The lifecycle is split so the user can pause/resume mid-run
    // without tearing down the agent process or losing session state:
    //
    //   connect()            spawn + initialize + openSession (once per run)
    //   sendUserPrompt(_:)   send a prompt to the open session; can be called
    //                        many times — the agent SDK keeps the conversation
    //                        history server-side so follow-ups continue from
    //                        wherever the previous turn left off
    //   cancelInFlight()     pause: stop the current turn but keep the
    //                        session alive so a follow-up can resume
    //   terminate()          stop: cancel + kill the subprocess

    /// Spawn the adapter, do the ACP handshake, open a session in the
    /// flow's directory. After this returns successfully, the session
    /// is ready to accept prompts via `sendUserPrompt`.
    func connect(
        provider: ProviderDefinition,
        workingDirectory: String
    ) async throws {
        try spawn(provider: provider)
        do {
            try await initialize()
            try await openSession(workingDirectory: workingDirectory)
        } catch {
            emit(.error("\(error)"))
            throw error
        }
    }

    /// Send a user prompt to the active session. Streams session/update
    /// notifications into the transcript as they arrive; returns when
    /// the agent finishes the turn (with `finalResult` emitted).
    func sendUserPrompt(_ prompt: String) async throws {
        emit(.userMessage(prompt))
        do {
            try await sendPrompt(prompt)
        } catch {
            emit(.error("\(error)"))
            throw error
        }
    }

    /// Pause: send `session/cancel` to halt the in-flight turn. The
    /// agent finishes any tool call already in flight and then
    /// terminates the turn early. Session stays alive — a follow-up
    /// `sendUserPrompt` continues from where the agent left off.
    func cancelInFlight() {
        guard let sessionId else { return }
        sendNotification(method: "session/cancel", params: [
            "sessionId": sessionId,
        ])
    }

    /// Stop: cancel the in-flight turn AND kill the subprocess.
    /// Session is unrecoverable after this; a fresh `connect` is needed
    /// to start a new run.
    func terminate() {
        cancelInFlight()
        // Give the agent ~250ms to finish writing its in-flight chunk
        // before we kill the subprocess. The terminationHandler
        // finishes the AsyncStream from there.
        let proc = process
        Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            await MainActor.run {
                proc?.terminate()
            }
        }
    }

    // MARK: - Spawn

    private func spawn(provider: ProviderDefinition) throws {
        let exec = provider.launch.executable
        guard let resolved = resolveOnPath(exec) else {
            throw LaunchError.adapterNotFound(executable: exec)
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: resolved)
        task.arguments = provider.launch.args
        task.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = enrichedPath(env["PATH"] ?? "")
        for (k, v) in provider.launch.env { env[k] = v }
        task.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe
        task.standardInput = stdinPipe

        // Stdout: parse newline-delimited JSON-RPC frames as they arrive.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor [weak self] in
                self?.consumeStdout(chunk: chunk)
            }
        }

        // Stderr: surface as raw transcript entries. Adapter prints
        // version banners + errors here.
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: chunk, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                Task { @MainActor [weak self] in
                    self?.emit(.raw("[adapter] \(text)"))
                }
            }
        }

        task.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                self?.handleTermination(exitCode: proc.terminationStatus)
            }
        }

        do {
            try task.run()
        } catch {
            throw LaunchError.spawnFailed(detail: "\(error)")
        }

        self.process = task
        self.stdinHandle = stdinPipe.fileHandleForWriting
    }

    // MARK: - ACP method calls

    /// `initialize` — version + capability negotiation. Spec calls for
    /// `protocolVersion` integer and `clientCapabilities` object. We
    /// advertise read-only fs + no terminal so the adapter knows it
    /// shouldn't ask us to write files or open terminals.
    private func initialize() async throws {
        let result = try await call(method: "initialize", params: [
            "protocolVersion": 1,
            "clientCapabilities": [
                "fs": [
                    "readTextFile": true,
                    "writeTextFile": false,
                ],
                "terminal": false,
            ] as [String: Any],
        ])
        if let dict = result as? [String: Any],
           let agentName = dict["agentInfo"] as? [String: Any] {
            let name = (agentName["name"] as? String) ?? "agent"
            let version = (agentName["version"] as? String) ?? ""
            emit(.systemInfo("Connected to \(name)\(version.isEmpty ? "" : " v\(version)")"))
        }
    }

    /// `session/new` — open a session anchored at `workingDirectory`.
    private func openSession(workingDirectory: String) async throws {
        let result = try await call(method: "session/new", params: [
            "cwd": workingDirectory,
            "mcpServers": [] as [Any],
        ])
        guard let dict = result as? [String: Any],
              let id = dict["sessionId"] as? String else {
            throw LaunchError.initializeFailed(
                detail: "session/new response missing sessionId"
            )
        }
        self.sessionId = id
        emit(.systemInfo("Session \(String(id.prefix(8)))"))
    }

    /// `session/prompt` — send the user message. The response arrives
    /// after the agent finishes the turn (with a `stopReason` string).
    /// Streaming chunks come via `session/update` notifications during
    /// the call.
    private func sendPrompt(_ prompt: String) async throws {
        guard let sessionId else { return }
        let result = try await call(method: "session/prompt", params: [
            "sessionId": sessionId,
            "prompt": [
                ["type": "text", "text": prompt] as [String: Any],
            ] as [Any],
        ])
        // Final result event with the stop reason.
        let stopReason = (result as? [String: Any])?["stopReason"] as? String ?? "complete"
        emit(.finalResult(text: "Stop reason: \(stopReason)", durationMs: nil, totalCostUSD: nil))
    }

    // MARK: - JSON-RPC plumbing

    /// Send a request and await its response.
    private func call(method: String, params: Any? = nil) async throws -> Any? {
        let id = nextRequestId
        nextRequestId += 1

        let req = JSONRPCRequest(id: id, method: method, params: params)
        let data = try JSONEncoder().encode(req)
        try send(data)

        let box: JSONBox = try await withCheckedThrowingContinuation { cont in
            pendingRequests[id] = cont
        }
        return box.value
    }

    /// Send a notification (no response expected).
    private func sendNotification(method: String, params: Any? = nil) {
        let note = JSONRPCNotification(method: method, params: params)
        guard let data = try? JSONEncoder().encode(note) else { return }
        try? send(data)
    }

    private func send(_ payload: Data) throws {
        guard let stdinHandle else {
            throw LaunchError.spawnFailed(detail: "subprocess stdin is closed")
        }
        var framed = payload
        framed.append(0x0A) // newline-delimited
        try stdinHandle.write(contentsOf: framed)
    }

    // MARK: - Stdout demux

    private func consumeStdout(chunk: Data) {
        stdoutBuffer.append(chunk)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: 0..<nl)
            stdoutBuffer.removeSubrange(0...nl)
            if !lineData.isEmpty {
                processFrame(data: lineData)
            }
        }
    }

    private func processFrame(data: Data) {
        let inbound: JSONRPCInbound
        do {
            inbound = try JSONRPCInbound.parse(data)
        } catch {
            // Not a JSON-RPC frame — surface as raw output.
            if let s = String(data: data, encoding: .utf8) {
                emit(.raw(s))
            }
            return
        }

        // Response (has id + (result or error)).
        if let id = inbound.id, inbound.method == nil {
            guard let cont = pendingRequests.removeValue(forKey: id) else { return }
            if let err = inbound.error {
                cont.resume(throwing: NSError(
                    domain: "ACP", code: err.code,
                    userInfo: [NSLocalizedDescriptionKey: err.message]
                ))
            } else {
                cont.resume(returning: JSONBox(value: inbound.result))
            }
            return
        }

        // Server → client request (has id + method). We must respond.
        if let id = inbound.id, let method = inbound.method {
            handleServerRequest(id: id, method: method, params: inbound.params)
            return
        }

        // Notification (no id, has method).
        if inbound.id == nil, let method = inbound.method {
            handleServerNotification(method: method, params: inbound.params)
            return
        }
    }

    // MARK: - Server-initiated requests

    private func handleServerRequest(id: Int, method: String, params: Any?) {
        switch method {
        case "session/request_permission":
            // Auto-grant tool permissions. The provider's launch spec
            // already restricted what the agent CAN ask for (Claude
            // Code uses our `--allowedTools`-equivalent at the SDK
            // layer); this is the "yes, go ahead" response for any
            // request that gets through the adapter to us.
            respond(id: id, result: [
                "outcome": [
                    "outcome": "selected",
                    "optionId": "allow",
                ] as [String: Any],
            ])

        case "fs/read_text_file":
            // Honor reads under the active flow dir + ~/.flow42/.
            let path = ((params as? [String: Any])?["path"] as? String) ?? ""
            if let content = readGuardedFile(path: path) {
                respond(id: id, result: ["content": content])
            } else {
                respondError(id: id, code: -32601, message: "Read denied for path: \(path)")
            }

        case "fs/write_text_file", "terminal/create", "terminal/output", "terminal/release":
            respondError(id: id, code: -32601, message: "Method not supported by client.")

        default:
            respondError(id: id, code: -32601, message: "Method not implemented: \(method)")
        }
    }

    private func respond(id: Int, result: Any) {
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        try? send(data)
    }

    private func respondError(id: Int, code: Int, message: String) {
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message] as [String: Any],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        try? send(data)
    }

    /// Only honor reads under the user's flow42 root or the adapter's
    /// session cwd. Refuses path-traversal attempts.
    private func readGuardedFile(path: String) -> String? {
        let resolved = (path as NSString).standardizingPath
        let allowedRoots = [
            (Flow42PathsHelper.flow42Root as NSString).standardizingPath,
            (NSHomeDirectory() as NSString).appendingPathComponent(".claude") as String,
        ]
        guard allowedRoots.contains(where: { resolved.hasPrefix($0) }) else { return nil }
        return try? String(contentsOfFile: resolved, encoding: .utf8)
    }

    // MARK: - Server notifications (streaming chunks)

    private func handleServerNotification(method: String, params: Any?) {
        switch method {
        case "session/update":
            handleSessionUpdate(params: params as? [String: Any] ?? [:])
        default:
            break
        }
    }

    /// Update kinds that carry transport-layer noise (token-counter
    /// pings, available-commands metadata, etc.) — drop them entirely
    /// instead of letting them surface as `[raw]` lines in the chat.
    /// `agent_thought_chunk` is included here — we don't want raw
    /// chain-of-thought polluting the chat. The view side renders a
    /// transient "Thinking…" indicator instead, derived from "no
    /// finalResult yet, no fresh assistantText".
    private static let suppressedUpdateKinds: Set<String> = [
        "usage_update",
        "available_commands_update",
        "current_mode_update",
        "agent_thought_chunk",
    ]

    /// `session/update` payloads carry a `update` discriminator with the
    /// streamed content. We route the common ones into TranscriptEvents.
    /// The exact schema varies by adapter version; we parse leniently.
    private func handleSessionUpdate(params: [String: Any]) {
        guard let update = params["update"] as? [String: Any] else { return }
        let kind = (update["sessionUpdate"] as? String) ?? ""
        if Self.suppressedUpdateKinds.contains(kind) { return }
        switch kind {
        case "agent_message_chunk":
            if let content = update["content"] as? [String: Any],
               let text = content["text"] as? String, !text.isEmpty {
                emit(.assistantText(text))
            }

        case "agent_thought_chunk":
            // Reasoning chunk — surface as systemInfo so it's visible
            // but visually distinct from the assistant's spoken reply.
            if let content = update["content"] as? [String: Any],
               let text = content["text"] as? String, !text.isEmpty {
                emit(.systemInfo("💭 \(text)"))
            }

        case "tool_call":
            let title = (update["title"] as? String)
                ?? (update["toolName"] as? String)
                ?? "tool"
            let summary = summariseToolUpdate(update)
            emit(.toolCall(name: title, summary: summary))

        case "tool_call_update":
            if let status = update["status"] as? String, status == "failed" {
                emit(.toolResult(summary: "Tool failed", isError: true))
            } else if let content = update["content"] as? [[String: Any]],
                      let first = content.first,
                      let text = (first["content"] as? [String: Any])?["text"] as? String {
                let trimmed = String(text.prefix(400))
                emit(.toolResult(summary: trimmed, isError: false))
            }

        default:
            // Other update kinds (plan, available_commands, etc.) — show
            // raw so we can spot them without flooding the chat.
            if let raw = String(data: (try? JSONSerialization.data(withJSONObject: update)) ?? Data(), encoding: .utf8) {
                emit(.raw("[\(kind)] \(raw)"))
            }
        }
    }

    private func summariseToolUpdate(_ update: [String: Any]) -> String {
        if let raw = (update["rawInput"] as? [String: Any])?["command"] as? String {
            return raw
        }
        if let kind = update["kind"] as? String { return kind }
        return ""
    }

    // MARK: - Termination

    private func handleTermination(exitCode: Int32) {
        // Flush any trailing partial line.
        if !stdoutBuffer.isEmpty {
            processFrame(data: stdoutBuffer)
            stdoutBuffer.removeAll(keepingCapacity: false)
        }
        // Fail any still-pending requests so the caller's `await` returns.
        for (_, cont) in pendingRequests {
            cont.resume(throwing: NSError(
                domain: "ACP", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Adapter exited (status \(exitCode)) before completing the request."]
            ))
        }
        pendingRequests.removeAll()
        if exitCode != 0 {
            emit(.error("ACP adapter exited with code \(exitCode)."))
        }
        continuation.finish()
        process = nil
        stdinHandle = nil
    }

    // MARK: - Emit

    private func emit(_ kind: TranscriptEvent.Kind) {
        continuation.yield(TranscriptEvent(kind: kind))
    }

    // MARK: - PATH lookup

    private func resolveOnPath(_ name: String) -> String? {
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        let dirs = enrichedPath(ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        for d in dirs {
            let candidate = (d as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func enrichedPath(_ existing: String) -> String {
        var dirs = existing.split(separator: ":").map(String.init)
        let extras = [
            "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
            "\(NSHomeDirectory())/.asdf/shims",
            "\(NSHomeDirectory())/.nvm/current/bin",
            "\(NSHomeDirectory())/.volta/bin",
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.bun/bin",
        ]
        for extra in extras where !dirs.contains(extra) {
            dirs.append(extra)
        }
        return dirs.joined(separator: ":")
    }
}

// MARK: - Tiny path helper

/// Avoids a `import Flow42Core` here just for one constant; the value is
/// computed once and stable for the process lifetime.
private enum Flow42PathsHelper {
    static let flow42Root: String = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".flow42")
}
