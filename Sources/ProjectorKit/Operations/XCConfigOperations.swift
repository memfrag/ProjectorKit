import Foundation
import PathKit
import XcodeProj

public extension ProjectorProject {
    /// Attaches an `.xcconfig` file as the base configuration for the
    /// configurations named by `scope`. The path is relative to the project's
    /// source root (or absolute). Idempotent.
    @discardableResult
    func setXCConfig(_ path: String, scope: SettingScope) throws -> OperationResult {
        let sourceRoot = xcodeprojPath.deletingLastPathComponent()
        let absolute = path.hasPrefix("/") ? URL(fileURLWithPath: path)
            : sourceRoot.appendingPathComponent(path)

        var changes: [ChangeDescription] = []
        let fileRef = try existingOrCreateXCConfigReference(at: absolute, sourceRoot: sourceRoot, changes: &changes)

        let configurations = try targetedConfigurationsForXCConfig(scope)
        for config in configurations where config.baseConfiguration !== fileRef {
            config.baseConfiguration = fileRef
            changes.append(ChangeDescription(
                kind: "xcconfig", detail: "attach \(path) [\(config.name)]",
                target: scope.debugTargetName))
        }

        return changes.isEmpty ? .alreadySatisfied : .applied(changes: changes)
    }

    private func existingOrCreateXCConfigReference(
        at absolute: URL, sourceRoot: URL, changes: inout [ChangeDescription]
    ) throws -> PBXFileReference {
        if let existing = pbxproj.fileReferences.first(where: {
            (try? $0.fullPath(sourceRoot: sourceRoot.path)).flatMap { $0 } == absolute.standardizedFileURL.path
        }) {
            return existing
        }
        let root = try rootProject
        let fileRef = try root.mainGroup.addFile(
            at: Path(absolute.path), sourceRoot: Path(sourceRoot.path), validatePresence: false)
        changes.append(ChangeDescription(kind: "fileReference", detail: "add \(absolute.lastPathComponent)"))
        return fileRef
    }

    private func targetedConfigurationsForXCConfig(_ scope: SettingScope) throws -> [XCBuildConfiguration] {
        let list: XCConfigurationList?
        switch scope.level {
        case .project: list = try rootProject.buildConfigurationList
        case .target(let name): list = try target(named: name).buildConfigurationList
        }
        guard let configurations = list?.buildConfigurations else { return [] }
        if let wanted = scope.configuration {
            return configurations.filter { $0.name == wanted }
        }
        return configurations
    }
}

extension SettingScope {
    var debugTargetName: String? {
        if case .target(let name) = level { return name }
        return nil
    }
}

// MARK: - Text-preserving edits to the .xcconfig file's own contents

/// Edits an `.xcconfig` file's raw text, preserving comments, includes, and
/// formatting for every line except the one being changed. XcodeProj's
/// `XCConfig` type is read-only-safe for parsing but drops comments on write,
/// so edits go directly against the text instead of through its object model.
public enum XCConfigEditor {
    /// The result of computing (but not necessarily applying) an edit.
    public struct Plan {
        public let originalText: String
        public let newText: String
        public var diff: DiffReport { DiffReport(old: originalText, new: newText) }
        public var hasChanges: Bool { originalText != newText }
    }

    /// Computes the effect of setting `key = value` in the xcconfig text at
    /// `url`. If the file doesn't exist, an empty document is assumed. If the
    /// key already has an active (non-commented) assignment, only the value
    /// portion of that line is replaced; otherwise a new line is appended.
    public static func plan(setting key: String, to value: String, in url: URL) throws -> Plan {
        let original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = original.isEmpty ? [] : original.components(separatedBy: "\n")
        // Preserve a trailing-newline-less last empty element from split; we
        // rejoin with "\n" so this matters for round-tripping exactly.
        let hadTrailingNewline = original.hasSuffix("\n")
        if hadTrailingNewline, lines.last == "" { lines.removeLast() }

        let assignmentRegex = try! NSRegularExpression(pattern: #"^(\s*)([A-Za-z_][A-Za-z0-9_]*)\s*="#)

        var replaced = false
        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = assignmentRegex.firstMatch(in: line, range: range),
                  let keyRange = Range(match.range(at: 2), in: line)
            else { continue }
            guard line[keyRange] == key else { continue }

            // Preserve everything up to and including "= ", replace the value,
            // keep a trailing "//" comment if present.
            guard let equalsIndex = line.firstIndex(of: "=") else { continue }
            let prefix = line[...equalsIndex]
            let rest = line[line.index(after: equalsIndex)...]
            let trailingComment = rest.range(of: "//").map { String(rest[$0.lowerBound...]) }
            let separator = rest.first == " " || rest.isEmpty ? " " : ""
            let newLine = "\(prefix)\(separator)\(value)" + (trailingComment.map { " \($0)" } ?? "")
            lines[index] = newLine
            replaced = true
            break
        }

        if !replaced {
            lines.append("\(key) = \(value)")
        }

        let newText = lines.joined(separator: "\n") + "\n"
        return Plan(originalText: original, newText: newText)
    }

    /// Applies a previously computed plan atomically (temp + rename), with an
    /// optional sibling backup.
    public static func apply(_ plan: Plan, to url: URL, backup: Bool = true) throws {
        guard plan.hasChanges else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicWriter.write(plan.newText, to: url, backup: backup)
    }
}
