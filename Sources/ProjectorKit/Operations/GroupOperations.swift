import Foundation
import XcodeProj

public extension ProjectorProject {
    /// Creates a navigator group (and any missing intermediate groups) at the
    /// given slash-separated path under the main group. Idempotent.
    @discardableResult
    func addGroup(path: String) throws -> OperationResult {
        var changes: [ChangeDescription] = []
        _ = try ensureGroup(path: path, changes: &changes)
        return changes.isEmpty ? .alreadySatisfied : .applied(changes: changes)
    }
}

extension ProjectorProject {
    /// Resolves the group at `path`, creating missing groups along the way and
    /// appending a change per created group. Returns the leaf group.
    func ensureGroup(path: String, changes: inout [ChangeDescription]) throws -> PBXGroup {
        let root = try rootProject
        var current = root.mainGroup!
        for component in path.split(separator: "/").map(String.init) {
            if let existing = current.children.compactMap({ $0 as? PBXGroup })
                .first(where: { $0.name == component || $0.path == component }) {
                current = existing
            } else {
                let created = try current.addGroup(named: component).last!
                changes.append(ChangeDescription(kind: "group", detail: "create group \(component)"))
                current = created
            }
        }
        return current
    }
}
