// ACPMessages.swift - Wire types for the Agent Client Protocol.
//
// ACP is JSON-RPC 2.0 over stdio (newline-delimited JSON). We don't try
// to model the full spec — only the shapes we actually send/receive for
// our use case:
//
//   client → agent:
//     initialize                      version + capability negotiation
//     session/new                     open a new session in a cwd
//     session/prompt                  send a user message
//     session/cancel (notification)   cancel an in-flight prompt
//
//   agent → client:
//     session/update (notification)   streaming chunks of the agent's
//                                     response (text, tool calls, results)
//     session/request_permission      ask us to allow / deny a tool call
//                                     before the agent runs it
//     fs/read_text_file (callback)    we stub: respond "not supported"
//
// The shapes use [String: AnyCodable] for the params/result envelopes
// because the spec is loose at the leaves and we only need to peek at
// specific fields. Everything else is left as raw JSON.

import Foundation

// MARK: - JSON-RPC envelopes

/// Outbound request. `id` correlates to a Response.
struct JSONRPCRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: AnyCodable?

    init(id: Int, method: String, params: Any? = nil) {
        self.id = id
        self.method = method
        self.params = params.map(AnyCodable.init)
    }
}

/// Outbound notification — no `id`, no response expected.
struct JSONRPCNotification: Encodable {
    let jsonrpc = "2.0"
    let method: String
    let params: AnyCodable?

    init(method: String, params: Any? = nil) {
        self.method = method
        self.params = params.map(AnyCodable.init)
    }
}

/// Either a response (has `id` + result/error) or a server-sent
/// notification (no `id`, has `method` + params). We discriminate on
/// presence at decode time.
struct JSONRPCInbound {
    /// Decoded by hand from JSON because the shape is union-y.
    let id: Int?
    let method: String?
    let result: Any?
    let error: JSONRPCError?
    let params: Any?

    static func parse(_ data: Data) throws -> JSONRPCInbound {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw NSError(domain: "ACP", code: -1) }
        let id = json["id"] as? Int
        let method = json["method"] as? String
        let result = json["result"]
        let params = json["params"]
        var error: JSONRPCError?
        if let errDict = json["error"] as? [String: Any] {
            error = JSONRPCError(
                code: (errDict["code"] as? Int) ?? -1,
                message: (errDict["message"] as? String) ?? "(no message)"
            )
        }
        return JSONRPCInbound(
            id: id, method: method, result: result, error: error, params: params
        )
    }
}

struct JSONRPCError: Equatable {
    let code: Int
    let message: String
}

// MARK: - Codable Any wrapper

/// Tiny Any-as-Codable helper so we can carry mixed JSON dicts through
/// `JSONRPCRequest`'s Encoder. Encode-only — decode goes through
/// JSONSerialization in JSONRPCInbound.parse for laxer error handling.
struct AnyCodable: Encodable {
    let value: Any

    init(_ value: Any) { self.value = value }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try Self.encodeAny(value, to: &container)
    }

    private static func encodeAny(_ v: Any, to c: inout SingleValueEncodingContainer) throws {
        switch v {
        case is NSNull:                         try c.encodeNil()
        case let b as Bool:                     try c.encode(b)
        case let i as Int:                      try c.encode(i)
        case let d as Double:                   try c.encode(d)
        case let s as String:                   try c.encode(s)
        case let arr as [Any]:                  try c.encode(arr.map(AnyCodable.init))
        case let dict as [String: Any]:
            try c.encode(dict.mapValues(AnyCodable.init))
        default:
            // Fallback — stringify unknown types.
            try c.encode(String(describing: v))
        }
    }
}
