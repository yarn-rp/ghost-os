// Framing.swift - Chrome native-messaging wire framing.
//
// Chrome's native-messaging protocol: each message is a 32-bit unsigned
// little-endian length, followed by that many bytes of UTF-8 JSON. Outbound
// messages have a 64 KB cap; inbound up to 1 MB. We treat both as opaque
// JSON objects.
//
// Stdout is sacred — Chrome reads framed bytes from there. Diagnostic
// logging goes to stderr (which Chrome discards by default; the install
// shim redirects it to a log file if --log-file is set).

import Foundation

public enum Framing {

    /// Read one JSON frame from `handle`. Returns nil on EOF.
    public static func read(_ handle: FileHandle) -> [String: Any]? {
        guard let header = readExact(handle: handle, count: 4) else { return nil }
        let length = header.withUnsafeBytes { ptr -> UInt32 in
            ptr.loadUnaligned(as: UInt32.self).littleEndian
        }
        guard length > 0, length <= 1_048_576 else { return nil }
        guard let payload = readExact(handle: handle, count: Int(length)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
    }

    /// Write one JSON frame to `handle`. Drops oversize frames.
    public static func write(_ handle: FileHandle, _ object: Any) {
        guard let payload = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.withoutEscapingSlashes]
        ) else { return }
        guard payload.count <= 65_536 else { return }
        var length = UInt32(payload.count).littleEndian
        let header = Data(bytes: &length, count: 4)
        try? handle.write(contentsOf: header + payload)
    }

    // MARK: - Internals

    private static func readExact(handle: FileHandle, count: Int) -> Data? {
        var buf = Data()
        buf.reserveCapacity(count)
        while buf.count < count {
            let need = count - buf.count
            let chunk: Data
            do {
                chunk = (try handle.read(upToCount: need)) ?? Data()
            } catch {
                return nil
            }
            if chunk.isEmpty { return nil }
            buf.append(chunk)
        }
        return buf
    }
}
