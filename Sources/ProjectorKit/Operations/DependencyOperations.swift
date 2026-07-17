import Foundation
import XcodeProj

public extension ProjectorProject {
    /// Adds a target dependency (`target` depends on `dependencyName`), wiring a
    /// same-project `PBXContainerItemProxy`. Idempotent.
    @discardableResult
    func addDependency(target targetName: String, on dependencyName: String) throws -> OperationResult {
        let dependent = try target(named: targetName)
        let dependency = try target(named: dependencyName)

        if dependent.dependencies.contains(where: { $0.target === dependency }) {
            return .alreadySatisfied
        }
        if dependent === dependency {
            throw ProjectorError.invalidOperation("Target '\(targetName)' cannot depend on itself")
        }

        let root = try rootProject
        let proxy = PBXContainerItemProxy(
            containerPortal: .project(root),
            remoteGlobalID: .object(dependency),
            proxyType: .nativeTarget,
            remoteInfo: dependency.name)
        pbxproj.add(object: proxy)

        let targetDependency = PBXTargetDependency(name: dependency.name, target: dependency, targetProxy: proxy)
        pbxproj.add(object: targetDependency)
        dependent.dependencies.append(targetDependency)

        return .applied(changes: [
            ChangeDescription(kind: "dependency", detail: "depend on \(dependencyName)", target: targetName),
        ])
    }

    /// Removes a target dependency. Idempotent.
    @discardableResult
    func removeDependency(target targetName: String, on dependencyName: String) throws -> OperationResult {
        let dependent = try target(named: targetName)
        guard let existing = dependent.dependencies.first(where: { $0.target?.name == dependencyName }) else {
            return .alreadySatisfied
        }
        dependent.dependencies.removeAll { $0 === existing }
        if let proxy = existing.targetProxy {
            pbxproj.delete(object: proxy)
        }
        pbxproj.delete(object: existing)
        return .applied(changes: [
            ChangeDescription(kind: "dependency", detail: "remove dependency on \(dependencyName)", target: targetName),
        ])
    }
}
