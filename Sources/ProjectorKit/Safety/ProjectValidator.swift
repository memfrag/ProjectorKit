import Foundation
import XcodeProj

/// Structural validation of a project graph. Errors block writes; warnings are
/// surfaced but do not.
public struct ProjectValidator {
    let project: ProjectorProject

    public init(project: ProjectorProject) {
        self.project = project
    }

    public func validate() -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let pbxproj = project.pbxproj

        // Root object present and sane.
        guard let root = try? pbxproj.rootProject() else {
            issues.append(ValidationIssue(
                severity: .error, rule: "missing-root-object",
                message: "pbxproj has no resolvable rootObject"))
            return issues
        }

        // Duplicate target names.
        var seenTargets: Set<String> = []
        for target in project.targets {
            if !seenTargets.insert(target.name).inserted {
                issues.append(ValidationIssue(
                    severity: .error, rule: "duplicate-target-name",
                    message: "More than one target named '\(target.name)'",
                    objectReference: target.uuid))
            }
            if target.buildConfigurationList == nil {
                issues.append(ValidationIssue(
                    severity: .error, rule: "target-missing-configurations",
                    message: "Target '\(target.name)' has no build configuration list",
                    objectReference: target.uuid))
            }
        }

        _ = root

        // Build files must point at something, and must live in some phase.
        var buildFilesInPhases: Set<String> = []
        for phase in pbxproj.buildPhases {
            for buildFile in phase.files ?? [] {
                buildFilesInPhases.insert(buildFile.uuid)
                if buildFile.file == nil, buildFile.product == nil {
                    issues.append(ValidationIssue(
                        severity: .error, rule: "dangling-build-file",
                        message: "Build file in phase '\(phase.name() ?? phase.buildPhase.rawValue)' resolves to no file or package product",
                        objectReference: buildFile.uuid))
                }
            }
        }
        for buildFile in pbxproj.buildFiles where !buildFilesInPhases.contains(buildFile.uuid) {
            issues.append(ValidationIssue(
                severity: .warning, rule: "orphaned-build-file",
                message: "PBXBuildFile is not referenced by any build phase",
                objectReference: buildFile.uuid))
        }

        // Duplicate children within a group.
        for group in pbxproj.groups {
            var seen: Set<String> = []
            for child in group.children {
                let key = child.path ?? child.name ?? ""
                guard !key.isEmpty else { continue }
                if !seen.insert(key).inserted {
                    issues.append(ValidationIssue(
                        severity: .warning, rule: "duplicate-group-child",
                        message: "Group '\(group.path ?? group.name ?? "<root>")' contains '\(key)' more than once",
                        objectReference: group.uuid))
                }
            }
        }

        // Exception sets must point at a live target.
        for root in pbxproj.fileSystemSynchronizedRootGroups {
            for exceptionSet in root.exceptions ?? [] {
                if let buildException = exceptionSet as? PBXFileSystemSynchronizedBuildFileExceptionSet,
                   buildException.target == nil {
                    issues.append(ValidationIssue(
                        severity: .error, rule: "dangling-exception-set-target",
                        message: "Exception set in synchronized folder '\(root.path ?? "?")' references a missing target",
                        objectReference: buildException.uuid))
                }
            }
        }

        // File references whose on-disk file is missing (warning: projects may
        // legitimately reference files created later).
        let inspector = Inspector(project: project)
        for fileRef in pbxproj.fileReferences {
            guard fileRef.sourceTree == .group || fileRef.sourceTree == .sourceRoot else { continue }
            let resolved = try? fileRef.fullPath(sourceRoot: inspector.sourceRoot.path)
            guard let full = resolved ?? nil else { continue }
            if !FileManager.default.fileExists(atPath: full) {
                issues.append(ValidationIssue(
                    severity: .warning, rule: "missing-file-on-disk",
                    message: "File reference points at missing file: \(full)",
                    objectReference: fileRef.uuid))
            }
        }

        return issues
    }
}
