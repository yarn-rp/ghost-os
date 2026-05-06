// ProjectStore.swift - The app-side observable for the project list +
// active project. Backed by `~/.flow42/config.yaml` (the existing
// `ConfigFile`).
//
// Lifecycle:
//   - On init, reads config.yaml (which seeds Personal if missing).
//   - addProject(at:) creates `.flow42/flows/` + `.flow42/config.yaml`
//     in the chosen folder, appends to projects, persists, switches
//     active.
//   - removeProject(_:) refuses pinned projects; never deletes folders.
//   - selectProject(_:) updates the active id and persists.
//
// SwiftUI binds to `@Published projects` for the sidebar and
// `@Published activeProjectId` for the detail surface; both surfaces
// stay in lockstep without extra wiring.

import Combine
import Foundation
import Yams

@MainActor
public final class ProjectStore: ObservableObject {

    @Published public private(set) var projects: [Flow42Project]
    @Published public private(set) var activeProjectId: String

    /// Convenience: resolve `activeProjectId` to the actual project. If
    /// the stored id is stale (project removed externally), falls back
    /// to Personal — which always exists.
    public var activeProject: Flow42Project {
        projects.first(where: { $0.id == activeProjectId })
            ?? projects.first(where: { $0.builtin })
            ?? .personal
    }

    public init() {
        let config = ConfigFile.read()
        self.projects = config.projects
        self.activeProjectId = config.activeProjectId
            ?? config.projects.first?.id
            ?? Flow42Project.personal.id
    }

    // MARK: - Selection

    /// Switch which project the sidebar treats as active. No-op if it's
    /// already active.
    public func selectProject(_ project: Flow42Project) {
        guard activeProjectId != project.id else { return }
        activeProjectId = project.id
        persist()
    }

    public func selectProject(id: String) {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        selectProject(project)
    }

    // MARK: - Add

    public enum AddError: Error, CustomStringConvertible {
        case folderInaccessible(path: String)
        case alreadyAdded(existingId: String)
        case writeFailed(detail: String)

        public var description: String {
            switch self {
            case .folderInaccessible(let p):
                return "Couldn't access \(p). Check permissions and try again."
            case .alreadyAdded:
                return "That folder is already in your project list."
            case .writeFailed(let d):
                return "Couldn't initialise the project: \(d)"
            }
        }
    }

    /// Add a folder as a user project. Auto-creates `.flow42/flows/` +
    /// `.flow42/config.yaml`. Idempotent — re-adding an existing
    /// project's folder switches active to it instead of creating a
    /// duplicate row.
    @discardableResult
    public func addProject(at folderPath: String) throws -> Flow42Project {
        let resolved = (folderPath as NSString).standardizingPath
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolved, isDirectory: &isDir),
              isDir.boolValue else {
            throw AddError.folderInaccessible(path: resolved)
        }

        // Idempotent: if a project already lives at this path, just
        // make it active.
        if let existing = projects.first(where: { ($0.path as NSString).standardizingPath == resolved }) {
            selectProject(existing)
            throw AddError.alreadyAdded(existingId: existing.id)
        }

        // Build the project record + scaffold its `.flow42/` directory.
        var project = Flow42Project.newUserProject(at: resolved)
        do {
            try fm.createDirectory(
                atPath: project.flowsRoot,
                withIntermediateDirectories: true
            )
            // Seed an empty per-project config (placeholder for future
            // per-project overrides — provider pin, model pin, etc.).
            // Not required to exist; we just create it so the user can
            // see the structure.
            if !fm.fileExists(atPath: project.configPath) {
                let stub = "schema_version: 1\n# Per-project Flow42 config.\n"
                try Data(stub.utf8).write(
                    to: URL(fileURLWithPath: project.configPath)
                )
            }
        } catch {
            throw AddError.writeFailed(detail: "\(error)")
        }

        projects.append(project)
        activeProjectId = project.id
        persist()
        return project
    }

    // MARK: - Remove

    /// Remove a project from the sidebar. Refuses pinned (built-in)
    /// projects. NEVER touches the folder on disk — the user's project
    /// folder stays intact; we just stop showing it.
    public func removeProject(_ project: Flow42Project) {
        guard !project.pinned else { return }
        projects.removeAll { $0.id == project.id }
        if activeProjectId == project.id {
            activeProjectId = projects.first?.id ?? Flow42Project.personal.id
        }
        persist()
    }

    // MARK: - Rename

    /// Update a project's display name. No-op for builtin projects (we
    /// keep "Personal" stable across users and migrations).
    public func renameProject(_ project: Flow42Project, to newName: String) {
        guard !project.builtin else { return }
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        var updated = projects[idx]
        updated.name = newName
        projects[idx] = updated
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        var config = ConfigFile.read()
        config.projects = projects
        config.activeProjectId = activeProjectId
        config.schemaVersion = 2
        try? ConfigFile.write(config)
    }
}
