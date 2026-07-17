import Foundation
import PathKit
import XcodeProj

public extension ProjectorProject {
    /// How an add-file operation was routed.
    enum FileAddMode: String, Sendable {
        /// Classic PBXGroup + PBXBuildFile bookkeeping.
        case classic
        /// The path lives under an Xcode 16 synchronized root folder, so
        /// membership is implicit (filesystem-only) or handled via exception sets.
        case synchronized
    }

    /// Adds a file to the project and links it into the given targets.
    ///
    /// - If the file's path is under a synchronized root folder, membership is
    ///   implicit for owning targets; only non-owner targets get an exception
    ///   set entry, and the pbxproj is otherwise untouched.
    /// - Otherwise a PBXFileReference is placed in `group` (default: the main
    ///   group) and a PBXBuildFile is added to the extension-appropriate phase
    ///   of each target.
    ///
    /// Idempotent: re-adding an already-linked file returns `.alreadySatisfied`.
    @discardableResult
    func addFile(
        at path: String,
        toTargets targetNames: [String],
        group groupPath: String? = nil,
        createOnDiskIfMissing: Bool = false
    ) throws -> OperationResult {
        let sourceRoot = xcodeprojPath.deletingLastPathComponent()
        let absolute = path.hasPrefix("/") ? URL(fileURLWithPath: path)
            : sourceRoot.appendingPathComponent(path)
        let relative = relativePath(of: absolute, to: sourceRoot)

        if createOnDiskIfMissing, !FileManager.default.fileExists(atPath: absolute.path) {
            try FileManager.default.createDirectory(
                at: absolute.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: absolute.path, contents: Data())
        }

        let targets = try targetNames.map { try target(named: $0) }

        // Synchronized routing: does the path fall under a synchronized root?
        if let root = synchronizedRoot(containing: relative) {
            return try addFileToSynchronizedRoot(
                root, relative: relative, absolute: absolute, targets: targets)
        }

        return try addFileClassic(
            absolute: absolute, relative: relative, sourceRoot: sourceRoot,
            groupPath: groupPath, targets: targets)
    }

    /// Removes a file from the project. For classic files this drops the file
    /// reference and its build files; for synchronized files it removes exception
    /// entries. Optionally deletes the file from disk.
    @discardableResult
    func removeFile(at path: String, deleteFromDisk: Bool = false) throws -> OperationResult {
        let sourceRoot = xcodeprojPath.deletingLastPathComponent()
        let absolute = path.hasPrefix("/") ? URL(fileURLWithPath: path)
            : sourceRoot.appendingPathComponent(path)
        let relative = relativePath(of: absolute, to: sourceRoot)

        var changes: [ChangeDescription] = []

        // Classic file reference?
        if let fileRef = pbxproj.fileReferences.first(where: {
            (try? $0.fullPath(sourceRoot: sourceRoot.path)).flatMap { $0 } == absolute.standardizedFileURL.path
        }) {
            // Remove build files referencing it.
            for phase in pbxproj.buildPhases {
                for buildFile in (phase.files ?? []) where buildFile.file === fileRef {
                    phase.files?.removeAll { $0 === buildFile }
                    pbxproj.delete(object: buildFile)
                    changes.append(ChangeDescription(kind: "buildFile", detail: "unlink \(relative)"))
                }
            }
            for group in pbxproj.groups {
                group.children.removeAll { $0 === fileRef }
            }
            pbxproj.delete(object: fileRef)
            changes.append(ChangeDescription(kind: "fileReference", detail: "remove \(relative)"))
        } else if let root = synchronizedRoot(containing: relative) {
            // Drop any exception-set membership entries for this path.
            let rootRelative = relativePath(of: absolute, to: sourceRoot)
            let inRoot = String(rootRelative.dropFirst((root.path ?? "").count + 1))
            for exceptionSet in (root.exceptions ?? []).compactMap({ $0 as? PBXFileSystemSynchronizedBuildFileExceptionSet }) {
                if exceptionSet.membershipExceptions?.contains(inRoot) == true {
                    exceptionSet.membershipExceptions?.removeAll { $0 == inRoot }
                    changes.append(ChangeDescription(kind: "exceptionSet", detail: "clear exception \(inRoot)"))
                }
            }
        }

        if deleteFromDisk, FileManager.default.fileExists(atPath: absolute.path) {
            try FileManager.default.removeItem(at: absolute)
            changes.append(ChangeDescription(kind: "fileSystem", detail: "delete \(relative)"))
        }

        return changes.isEmpty ? .alreadySatisfied : .applied(changes: changes)
    }

    // MARK: - Classic

    private func addFileClassic(
        absolute: URL, relative: String, sourceRoot: URL,
        groupPath: String?, targets: [PBXTarget]
    ) throws -> OperationResult {
        var changes: [ChangeDescription] = []
        let root = try rootProject

        // Resolve or create the destination group.
        let destinationGroup: PBXGroup
        if let groupPath, !groupPath.isEmpty {
            destinationGroup = try ensureGroup(path: groupPath, changes: &changes)
        } else {
            destinationGroup = root.mainGroup
        }

        let existedBefore = pbxproj.fileReferences.contains {
            (try? $0.fullPath(sourceRoot: sourceRoot.path)).flatMap { $0 } == absolute.standardizedFileURL.path
        }

        let fileRef = try destinationGroup.addFile(
            at: Path(absolute.path), sourceRoot: Path(sourceRoot.path), validatePresence: false)
        if !existedBefore {
            changes.append(ChangeDescription(kind: "fileReference", detail: "add \(relative)"))
        }

        // Link into each target's appropriate phase.
        let ext = absolute.pathExtension
        for target in targets {
            let isFramework = (target as? PBXNativeTarget)?.productType?.rawValue.contains("framework") ?? false
            let phaseKind = BuildPhaseMapping.phase(forExtension: ext, isFrameworkTarget: isFramework)
            guard let phase = try buildPhase(phaseKind, of: target) else { continue }
            let before = phase.files?.count ?? 0
            _ = try phase.add(file: fileRef)
            if (phase.files?.count ?? 0) > before {
                changes.append(ChangeDescription(
                    kind: "buildFile", detail: "link \(relative) into \(phaseKind)", target: target.name))
            }
        }

        return changes.isEmpty ? .alreadySatisfied : .applied(changes: changes)
    }

    private func buildPhase(_ kind: BuildPhaseMapping.Phase, of target: PBXTarget) throws -> PBXBuildPhase? {
        switch kind {
        case .sources: return try target.sourcesBuildPhase()
        case .resources: return try target.resourcesBuildPhase()
        case .frameworks: return try target.frameworksBuildPhase()
        case .headers: return target.buildPhases.first { $0 is PBXHeadersBuildPhase }
        case .none: return nil
        }
    }

    // MARK: - Synchronized

    private func addFileToSynchronizedRoot(
        _ root: PBXFileSystemSynchronizedRootGroup, relative: String, absolute: URL, targets: [PBXTarget]
    ) throws -> OperationResult {
        var changes: [ChangeDescription] = []
        let rootPath = root.path ?? ""
        let inRoot = relative.hasPrefix(rootPath + "/") ? String(relative.dropFirst(rootPath.count + 1)) : relative

        if !FileManager.default.fileExists(atPath: absolute.path) {
            note("File \(relative) is under synchronized folder '\(rootPath)' but does not exist on disk; Xcode will not see it until it is created.")
        }

        for target in targets {
            let owns = (target.fileSystemSynchronizedGroups ?? []).contains { $0 === root }
            if owns {
                // Already a member by virtue of the folder; nothing to write.
                continue
            }
            // Non-owner target opting in: record a membership exception.
            let exceptionSet = existingOrNewExceptionSet(for: target, in: root, changes: &changes)
            if exceptionSet.membershipExceptions?.contains(inRoot) != true {
                exceptionSet.membershipExceptions = (exceptionSet.membershipExceptions ?? []) + [inRoot]
                changes.append(ChangeDescription(
                    kind: "exceptionSet", detail: "include \(inRoot)", target: target.name))
            }
        }

        return changes.isEmpty ? .alreadySatisfied : .applied(changes: changes)
    }

    private func existingOrNewExceptionSet(
        for target: PBXTarget, in root: PBXFileSystemSynchronizedRootGroup,
        changes: inout [ChangeDescription]
    ) -> PBXFileSystemSynchronizedBuildFileExceptionSet {
        let existing = (root.exceptions ?? [])
            .compactMap { $0 as? PBXFileSystemSynchronizedBuildFileExceptionSet }
            .first { $0.target === target }
        if let existing { return existing }
        let created = PBXFileSystemSynchronizedBuildFileExceptionSet(
            target: target, membershipExceptions: [], publicHeaders: nil,
            privateHeaders: nil, additionalCompilerFlagsByRelativePath: nil,
            attributesByRelativePath: nil)
        pbxproj.add(object: created)
        root.exceptions = (root.exceptions ?? []) + [created]
        changes.append(ChangeDescription(
            kind: "exceptionSet", detail: "create exception set", target: target.name))
        return created
    }

    // MARK: - Helpers

    private func synchronizedRoot(containing relative: String) -> PBXFileSystemSynchronizedRootGroup? {
        pbxproj.fileSystemSynchronizedRootGroups.first { root in
            guard let rootPath = root.path else { return false }
            return relative == rootPath || relative.hasPrefix(rootPath + "/")
        }
    }

    private func relativePath(of url: URL, to root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        if full.hasPrefix(rootPath + "/") {
            return String(full.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }
}
