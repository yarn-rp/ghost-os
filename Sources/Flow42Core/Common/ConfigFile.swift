// ConfigFile.swift - Shared `~/.flow42/config.yaml` reader/writer.
//
// Persistent user preferences. Distinct from StateFile (transient
// session state): config survives across launches and is the source of
// truth for "which AI provider am I connected to?" plus "which projects
// has the user opened?".
//
// YAML on disk because the user may reasonably hand-edit this; JSON is
// the wrong shape for that. We use Yams for the same reason flow.yaml
// does.
//
// Writes are atomic (temp + rename) so a reader never sees a half-
// written file. Schema is versioned with a tolerant decoder so v1
// configs (provider only) upgrade in-memory to v2 (provider + projects)
// on first read without exploding.

import Foundation
import Yams

// MARK: - Schema

public nonisolated struct AppConfig: Sendable, Codable, Equatable {
    /// Schema version. v1 = provider only. v2 = provider + projects +
    /// activeProjectId. The decoder tolerates a missing version field
    /// or a v1 file (no `projects` key) and upgrades in memory.
    public var schemaVersion: Int

    public var provider: ProviderConfig?

    /// All projects known to the user, in display order. The first
    /// entry is always the built-in Personal project (pinned, builtin)
    /// pointing at `~/.flow42/`. We seed it on first read of any v1
    /// config so existing users land somewhere sensible.
    public var projects: [Flow42Project]

    /// Which project the sidebar should highlight as active. Falls back
    /// to `projects.first?.id` when nil or stale.
    public var activeProjectId: String?

    public init(
        provider: ProviderConfig? = nil,
        projects: [Flow42Project]? = nil,
        activeProjectId: String? = nil
    ) {
        self.schemaVersion = 2
        self.provider = provider
        self.projects = projects ?? [Flow42Project.personal]
        self.activeProjectId = activeProjectId ?? projects?.first?.id ?? Flow42Project.personal.id
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case provider
        case projects
        case activeProjectId = "active_project_id"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
        self.provider = try c.decodeIfPresent(ProviderConfig.self, forKey: .provider)
        // v1 → v2 migration: missing projects = seed Personal.
        let decoded = try c.decodeIfPresent([Flow42Project].self, forKey: .projects) ?? []
        let merged = decoded.contains(where: { $0.builtin })
            ? decoded
            : [Flow42Project.personal] + decoded
        self.projects = merged
        self.activeProjectId = try c.decodeIfPresent(String.self, forKey: .activeProjectId)
            ?? merged.first?.id
    }
}

public nonisolated struct ProviderConfig: Sendable, Codable, Equatable {
    /// Stable id from the provider registry (e.g. "claude", "codex").
    /// Not the display name — that comes from the registry at read time
    /// so renames don't invalidate the config.
    public var id: String

    public init(id: String) {
        self.id = id
    }
}

// MARK: - Reader / writer

public nonisolated enum ConfigFile {

    /// Path to the config file. Public so tooling can locate it.
    public static func path() -> String {
        Flow42Paths.configFile()
    }

    /// Read the current config. Returns a fresh (Personal-only) config
    /// when the file is missing or unparseable — absence is the
    /// canonical "first-run / no projects yet" signal.
    public static func read() -> AppConfig {
        let p = path()
        guard FileManager.default.fileExists(atPath: p),
              let yaml = try? String(contentsOf: URL(fileURLWithPath: p), encoding: .utf8),
              let config = try? YAMLDecoder().decode(AppConfig.self, from: yaml)
        else {
            return AppConfig()
        }
        return config
    }

    /// Atomically write a new config. Returns bytes written, or throws
    /// on I/O failure. Never partially writes.
    @discardableResult
    public static func write(_ config: AppConfig) throws -> Int {
        let p = path()
        let dir = (p as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )

        let yaml = try YAMLEncoder().encode(config)
        let data = Data(yaml.utf8)

        let tmpPath = p + ".tmp.\(getpid())"
        try data.write(to: URL(fileURLWithPath: tmpPath))
        // POSIX rename is atomic on the same filesystem.
        if rename(tmpPath, p) != 0 {
            try? FileManager.default.removeItem(atPath: tmpPath)
            throw NSError(
                domain: "Flow42ConfigFile",
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "rename failed: \(String(cString: strerror(errno)))"]
            )
        }
        return data.count
    }

    /// Convenience: update just the provider id.
    public static func setProvider(id: String) throws {
        var config = read()
        config.provider = ProviderConfig(id: id)
        try write(config)
    }
}
