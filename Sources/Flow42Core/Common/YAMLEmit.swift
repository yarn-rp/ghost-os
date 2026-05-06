// YAMLEmit.swift - Deterministic minimal YAML emitter.
//
// We emit YAML for the per-step `meta.yaml` and the session `meta.yaml` from
// Swift on the recording hot path. Reading YAML — including the agent-
// authored `flow.yaml` — happens later, in `flow42 view`, and uses Yams.
// This file deliberately does no parsing.
//
// Goals:
//   - Deterministic output: same input dict → byte-identical YAML, regardless
//     of process or run. Required for round-trip checks against Yams in
//     Phase B and for clean diffs between sessions.
//   - "Enough" YAML: the schemas we own are flat key→primitive, key→string,
//     key→[primitive], key→[dict]. Block style only — no flow-style mappings,
//     no anchors, no aliases, no tags. Strings always double-quoted. Multi-
//     line strings get the literal block-scalar form (`|`).
//   - No SPM dep on the recording hot path. Yams is fine in `flow42 view`,
//     but pulling it into Flow42Core just to emit `meta.yaml` would cost us
//     a build-step regression on every recorder call.
//
// Things we intentionally don't support:
//   - Booleans aren't quoted; they're written as `true` / `false`.
//   - Numeric strings ("42") are emitted as quoted strings, not bare ints.
//     Callers pass real ints / doubles when they want unquoted numbers.
//   - Cycles: an array containing itself will recurse forever. Don't do
//     that — our schemas are trees.

import Foundation

public enum YAMLEmit {

    /// Emit a top-level mapping. Output ends with a single trailing newline.
    /// Keys are sorted alphabetically (deterministic).
    public nonisolated static func mapping(_ dict: [String: Any]) -> String {
        var out = ""
        emitMapping(dict, indent: 0, into: &out)
        return out
    }

    // MARK: - Internals

    private nonisolated static func emitMapping(
        _ dict: [String: Any],
        indent: Int,
        into out: inout String
    ) {
        let pad = String(repeating: "  ", count: indent)
        let keys = dict.keys.sorted()
        for key in keys {
            let value = dict[key]!
            out += pad
            out += escapeKey(key)
            out += ":"
            emitValue(value, indent: indent, into: &out)
        }
    }

    /// Emit the value side of a `key:`. Caller has already written the
    /// "key:" prefix; we decide whether the value is inline (` value\n`),
    /// a block (newline-prefixed multi-line string), or a nested structure
    /// (newline + indented children).
    private nonisolated static func emitValue(
        _ value: Any,
        indent: Int,
        into out: inout String
    ) {
        switch value {
        case is NSNull:
            out += " null\n"

        case let s as String:
            if s.contains("\n") {
                // Literal block scalar. Strip clip indicator (default keep
                // the trailing newline if any), preserve internal newlines.
                out += " |\n"
                let pad = String(repeating: "  ", count: indent + 1)
                for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
                    out += pad
                    out += String(line)
                    out += "\n"
                }
            } else {
                out += " "
                out += escapeString(s)
                out += "\n"
            }

        case let b as Bool:
            // Bool MUST come before Int — `Bool` is convertible to `NSNumber`
            // in Foundation interop, so an unguarded `as? Int` would catch
            // `true` first.
            out += b ? " true\n" : " false\n"

        case let n as Int:
            out += " \(n)\n"

        case let n as Int64:
            out += " \(n)\n"

        case let n as UInt64:
            // mach_absolute_time() returns UInt64. Without this case, the
            // fallback below stringifies it ("8550169627638") which made
            // the recorder's `timestamp` field look like a string instead
            // of a number.
            out += " \(n)\n"

        case let n as Double:
            out += " \(formatDouble(n))\n"

        case let arr as [Any]:
            if arr.isEmpty {
                out += " []\n"
            } else {
                out += "\n"
                emitArray(arr, indent: indent + 1, into: &out)
            }

        case let m as [String: Any]:
            if m.isEmpty {
                out += " {}\n"
            } else {
                out += "\n"
                emitMapping(m, indent: indent + 1, into: &out)
            }

        default:
            // Fallback — coerce via String(describing:) and emit as a
            // quoted scalar so we never crash a recording on a stray type.
            out += " "
            out += escapeString(String(describing: value))
            out += "\n"
        }
    }

    private nonisolated static func emitArray(
        _ arr: [Any],
        indent: Int,
        into out: inout String
    ) {
        let pad = String(repeating: "  ", count: indent)
        for value in arr {
            switch value {
            case let m as [String: Any]:
                // `- key: value` on the same line as the dash, then the rest
                // of the dict at the next indent.
                let keys = m.keys.sorted()
                guard let firstKey = keys.first else {
                    out += pad
                    out += "- {}\n"
                    continue
                }
                out += pad
                out += "- "
                out += escapeKey(firstKey)
                out += ":"
                emitValue(m[firstKey]!, indent: indent + 1, into: &out)
                // Remaining keys — at indent+1 so they line up with the
                // first key after the `- ` prefix (which is two chars wide).
                for key in keys.dropFirst() {
                    out += String(repeating: "  ", count: indent + 1)
                    out += escapeKey(key)
                    out += ":"
                    emitValue(m[key]!, indent: indent + 1, into: &out)
                }

            default:
                // Scalar item: `- value`. Reuse emitValue but strip its
                // leading space + trailing newline for inline form.
                var tail = ""
                emitValue(value, indent: indent, into: &tail)
                let trimmed = tail.hasPrefix(" ")
                    ? String(tail.dropFirst())
                    : tail
                out += pad
                out += "- "
                out += trimmed
            }
        }
    }

    /// Quote keys only when they'd be ambiguous bare-string YAML (contain
    /// special chars, start with a digit, or look like a YAML keyword).
    /// Our schemas use snake_case identifiers, which are always safe bare.
    private nonisolated static func escapeKey(_ key: String) -> String {
        if key.isEmpty { return "\"\"" }
        let safe = key.allSatisfy { c in
            c.isLetter || c.isNumber || c == "_" || c == "-"
        }
        let firstIsDigit = key.first.map { $0.isNumber } ?? false
        if safe && !firstIsDigit { return key }
        return escapeString(key)
    }

    /// Always-quoted string emit. We use double quotes and escape the four
    /// characters YAML requires inside a double-quoted scalar.
    private nonisolated static func escapeString(_ s: String) -> String {
        var out = "\""
        for c in s {
            switch c {
            case "\\":  out += "\\\\"
            case "\"":  out += "\\\""
            case "\n":  out += "\\n"
            case "\t":  out += "\\t"
            case "\r":  out += "\\r"
            default:    out.append(c)
            }
        }
        out += "\""
        return out
    }

    private nonisolated static func formatDouble(_ d: Double) -> String {
        // Avoid printing "1e+20" or weirdness; use `%g` semantics with
        // enough precision for our use cases (timestamps in ms, screen coords
        // are fine as integers anyway).
        if d == d.rounded() && abs(d) < 1e15 {
            return "\(Int64(d))"
        }
        return String(d)
    }
}
