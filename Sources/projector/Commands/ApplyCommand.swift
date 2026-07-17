import ArgumentParser
import Foundation
import ProjectorKit

/// Batch-applies a JSON array of operations against a single loaded project,
/// so a multi-step edit ("add 3 files, a package, and a setting") is one
/// parse, one write, and one diff instead of N of each — and can't be
/// interleaved with another process (e.g. Xcode) touching the file mid-sequence.
///
/// Supports only operations that flow through the pbxproj graph (files,
/// groups, targets, dependencies, packages, build settings, xcconfig attach).
/// Schemes and plist/entitlement edits use separate direct-file-write
/// mechanisms that don't compose with "one write" semantics and are not
/// included; run those as individual commands.
struct ApplyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Apply a batch of operations from a JSON file (or '-' for stdin) as a single transaction.",
        discussion: """
        Input is a JSON array of operation objects, each with an "op" \
        discriminator:

          {"op": "add-file", "path": "Foo.swift", "targets": ["App"], "group": "Sources"}
          {"op": "remove-file", "path": "Old.swift", "delete": true}
          {"op": "add-group", "path": "Sources/Networking"}
          {"op": "add-target", "name": "Tool", "type": "commandLineTool", "platform": "macOS"}
          {"op": "remove-target", "name": "Tool"}
          {"op": "add-dependency", "target": "App", "on": "Tool"}
          {"op": "remove-dependency", "target": "App", "on": "Tool"}
          {"op": "add-package", "url": "https://...", "product": "Logging", "target": "App", "requirement": "upToNextMajor:1.5.0"}
          {"op": "add-package", "path": "../LocalPkg", "local": true, "product": "LocalLib", "target": "App"}
          {"op": "remove-package", "location": "https://..."}
          {"op": "set-build-setting", "key": "SWIFT_VERSION", "value": "6.0", "target": "App"}
          {"op": "unset-build-setting", "key": "SWIFT_VERSION", "target": "App"}
          {"op": "set-xcconfig", "path": "Shared.xcconfig", "target": "App", "configuration": "Debug"}

        "target"/"targets"/"group"/"configuration" are optional where shown \
        optional elsewhere in individual commands.
        """
    )

    @OptionGroup var options: GlobalOptions
    @OptionGroup var mutation: MutationOptions

    @Argument(help: "Path to a JSON file of operations, or '-' to read from stdin.")
    var input: String

    struct Payload: Encodable {
        let applied: Int
        let alreadySatisfied: Int
        let changes: [ChangeDescription]
    }

    func run() throws {
        try runCommand(json: options.json) {
            let text: String
            if input == "-" {
                text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
            } else {
                text = try String(contentsOf: URL(fileURLWithPath: input), encoding: .utf8)
            }
            guard let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else {
                throw ProjectorError.invalidOperation("Input must be a JSON array of operation objects")
            }

            let project = try options.loadProject()
            var applied = 0
            var alreadySatisfied = 0
            var allChanges: [ChangeDescription] = []

            for (index, rawOp) in json.enumerated() {
                let result = try BatchOperation.apply(rawOp, to: project, index: index)
                if result.isApplied {
                    applied += 1
                    allChanges.append(contentsOf: result.changes)
                } else {
                    alreadySatisfied += 1
                }
            }

            let combined: OperationResult = applied > 0 ? .applied(changes: allChanges) : .alreadySatisfied
            try MutationRunner.finish(
                action: "apply", project: project, operation: combined,
                options: options, mutation: mutation)
        }
    }
}

/// Decodes and applies one operation dictionary. Kept separate from
/// ApplyCommand for readability; not meant for reuse elsewhere.
enum BatchOperation {
    static func apply(_ raw: [String: Any], to project: ProjectorProject, index: Int) throws -> OperationResult {
        guard let op = raw["op"] as? String else {
            throw ProjectorError.invalidOperation("Operation #\(index) is missing an \"op\" field")
        }

        func field(_ key: String) throws -> String {
            guard let value = raw[key] as? String else {
                throw ProjectorError.invalidOperation("Operation #\(index) (\(op)) is missing required field \"\(key)\"")
            }
            return value
        }
        func optionalField(_ key: String) -> String? { raw[key] as? String }
        func optionalBool(_ key: String) -> Bool { (raw[key] as? Bool) ?? false }
        func optionalStringArray(_ key: String) -> [String] { (raw[key] as? [String]) ?? [] }

        switch op {
        case "add-file":
            return try project.addFile(
                at: try field("path"),
                toTargets: (raw["targets"] as? [String]) ?? optionalField("target").map { [$0] } ?? [],
                group: optionalField("group"),
                createOnDiskIfMissing: optionalBool("createOnDisk"))

        case "remove-file":
            return try project.removeFile(at: try field("path"), deleteFromDisk: optionalBool("delete"))

        case "add-group":
            return try project.addGroup(path: try field("path"))

        case "add-target":
            guard let typeRaw = raw["type"] as? String, let type = TargetSpec.ProductType(rawValue: typeRaw) else {
                throw ProjectorError.invalidOperation(
                    "Operation #\(index) (add-target) has an invalid or missing \"type\". Valid: \(TargetSpec.ProductType.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            let platform = (raw["platform"] as? String).flatMap(TargetSpec.Platform.init) ?? .macOS
            let spec = TargetSpec(
                name: try field("name"), productType: type, platform: platform,
                bundleIdentifier: optionalField("bundleId"), deploymentTarget: optionalField("deploymentTarget"),
                testHostTarget: optionalField("testHost"))
            return try project.addTarget(spec)

        case "remove-target":
            return try project.removeTarget(try field("name"))

        case "add-dependency":
            return try project.addDependency(target: try field("target"), on: try field("on"))

        case "remove-dependency":
            return try project.removeDependency(target: try field("target"), on: try field("on"))

        case "add-package":
            let product = try field("product")
            let target = try field("target")
            if optionalBool("local") {
                return try project.addLocalPackage(path: try field("path"), product: product, target: target)
            }
            let requirement = try parseRequirement(optionalField("requirement") ?? "upToNextMajor:1.0.0", index: index)
            return try project.addRemotePackage(url: try field("url"), requirement: requirement, product: product, target: target)

        case "remove-package":
            return try project.removePackage(urlOrPath: try field("location"))

        case "set-build-setting":
            let scope: SettingScope = optionalField("target").map { .target($0, configuration: optionalField("configuration")) }
                ?? .project(configuration: optionalField("configuration"))
            return try project.setBuildSetting(try field("key"), to: .string(try field("value")), scope: scope)

        case "unset-build-setting":
            let scope: SettingScope = optionalField("target").map { .target($0, configuration: optionalField("configuration")) }
                ?? .project(configuration: optionalField("configuration"))
            return try project.unsetBuildSetting(try field("key"), scope: scope)

        case "set-xcconfig":
            let scope: SettingScope = optionalField("target").map { .target($0, configuration: optionalField("configuration")) }
                ?? .project(configuration: optionalField("configuration"))
            return try project.setXCConfig(try field("path"), scope: scope)

        default:
            throw ProjectorError.invalidOperation("Operation #\(index) has unknown \"op\": \(op)")
        }
    }

    private static func parseRequirement(_ raw: String, index: Int) throws -> PackageRequirement {
        let parts = raw.split(separator: ":", maxSplits: 2).map(String.init)
        switch parts.first {
        case "upToNextMajor": return .upToNextMajor(parts[1])
        case "upToNextMinor": return .upToNextMinor(parts[1])
        case "exact": return .exact(parts[1])
        case "branch": return .branch(parts[1])
        case "revision": return .revision(parts[1])
        case "range" where parts.count == 3: return .range(from: parts[1], to: parts[2])
        default:
            throw ProjectorError.invalidOperation("Operation #\(index) has an unrecognized version requirement: \(raw)")
        }
    }
}
