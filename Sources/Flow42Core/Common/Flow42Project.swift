// Flow42Project.swift - One project (a folder the user has "opened"
// in Flow42 + its `.flow42/` subdirectory containing flows). Plus the
// special pinned "Personal" project pointing at `~/.flow42/`.
//
// Persisted inside `~/.flow42/config.yaml` under the `projects` key.

import Foundation

public nonisolated struct Flow42Project: Sendable, Codable, Equatable, Identifiable, Hashable {

    /// Stable id. For Personal, the literal string "personal" — referenced
    /// by static helpers below. For user projects, a UUID generated at
    /// add time.
    public let id: String

    /// User-visible name. For Personal, "Personal". For user projects,
    /// auto-derived from the folder leaf at add time, but the user can
    /// rename later.
    public var name: String

    /// Absolute path the user picked. For Personal, this is the
    /// `~/.flow42/` root directly (its `.flow42` IS the root). For user
    /// projects, this is the project folder; flows live under
    /// `<path>/.flow42/flows/`.
    public var path: String

    /// True for the built-in Personal project. Pinned projects can't be
    /// removed from the sidebar.
    public var pinned: Bool

    /// True for the built-in Personal project. Builtin projects use the
    /// container path itself as `dotFlow42Path` (instead of appending
    /// `.flow42`) since `~/.flow42` already IS the dotFlow42 dir.
    public var builtin: Bool

    /// When the user added this project. Personal is nil (it's there
    /// from the beginning). Used to sort secondary projects by recency
    /// in the sidebar.
    public var addedAt: Date?

    public init(
        id: String,
        name: String,
        path: String,
        pinned: Bool = false,
        builtin: Bool = false,
        addedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.pinned = pinned
        self.builtin = builtin
        self.addedAt = addedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, path, pinned, builtin
        case addedAt = "added_at"
    }

    // MARK: - Path computations

    /// `<path>/.flow42/` for user projects, `<path>/` itself for the
    /// built-in Personal project.
    public var dotFlow42Path: String {
        if builtin { return path }
        return (path as NSString).appendingPathComponent(".flow42")
    }

    /// `<dotFlow42Path>/flows/`. The directory `FlowsRepository` watches
    /// for this project.
    public var flowsRoot: String {
        (dotFlow42Path as NSString).appendingPathComponent("flows")
    }

    /// `<dotFlow42Path>/config.yaml`. Optional per-project overrides;
    /// not required to exist.
    public var configPath: String {
        (dotFlow42Path as NSString).appendingPathComponent("config.yaml")
    }

    // MARK: - Built-in Personal

    /// The pinned, built-in project pointing at `~/.flow42/`. All
    /// existing flows from before the project model land here on first
    /// read.
    public static var personal: Flow42Project {
        Flow42Project(
            id: "personal",
            name: "Personal",
            path: Flow42Paths.root(),
            pinned: true,
            builtin: true,
            addedAt: nil
        )
    }

    // MARK: - Initializer for the "open a folder" flow

    /// Build a Flow42Project for a folder the user just picked. Caller
    /// is responsible for actually creating the `.flow42/` subdirectory
    /// and seeding it (see `ProjectStore.addProject`).
    public static func newUserProject(at folderPath: String) -> Flow42Project {
        let leaf = (folderPath as NSString).lastPathComponent
        return Flow42Project(
            id: UUID().uuidString,
            name: leaf.isEmpty ? "Untitled" : leaf,
            path: folderPath,
            pinned: false,
            builtin: false,
            addedAt: Date()
        )
    }
}
