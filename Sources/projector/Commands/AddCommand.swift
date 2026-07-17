import ArgumentParser
import Foundation
import ProjectorKit

struct AddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add an entity to the project.",
        subcommands: [
            AddFile.self, AddGroup.self, AddTarget.self,
            AddDependency.self, AddPackage.self,
        ]
    )
}

struct AddFile: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "file",
        abstract: "Add a file and link it into one or more targets."
    )

    @OptionGroup var options: GlobalOptions
    @OptionGroup var mutation: MutationOptions

    @Argument(help: "Path to the file, relative to the project directory (or absolute).")
    var path: String

    @Option(name: .long, parsing: .upToNextOption, help: "Target(s) to link the file into.")
    var target: [String] = []

    @Option(name: .long, help: "Group path to place the file under (classic projects). Defaults to the main group.")
    var group: String?

    @Flag(name: .long, help: "Create an empty file on disk if it does not exist.")
    var createOnDisk = false

    func run() throws {
        try runCommand(json: options.json) {
            let project = try options.loadProject()
            let result = try project.addFile(
                at: path, toTargets: target, group: group,
                createOnDiskIfMissing: createOnDisk)
            try MutationRunner.finish(
                action: "add-file", project: project,
                operation: result, options: options, mutation: mutation)
        }
    }
}

struct AddGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "group",
        abstract: "Add a navigator group."
    )

    @OptionGroup var options: GlobalOptions
    @OptionGroup var mutation: MutationOptions

    @Argument(help: "Group path, e.g. Sources/Networking.")
    var path: String

    func run() throws {
        try runCommand(json: options.json) {
            let project = try options.loadProject()
            let result = try project.addGroup(path: path)
            try MutationRunner.finish(
                action: "add-group", project: project,
                operation: result, options: options, mutation: mutation)
        }
    }
}

struct AddTarget: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "target",
        abstract: "Create a new target."
    )

    @OptionGroup var options: GlobalOptions
    @OptionGroup var mutation: MutationOptions

    @Argument(help: "Target name.")
    var name: String

    @Option(name: .long, help: "Product type: \(TargetSpec.ProductType.allCases.map(\.rawValue).joined(separator: ", ")).")
    var type: TargetSpec.ProductType

    @Option(name: .long, help: "Platform: macOS, iOS, tvOS, watchOS.")
    var platform: TargetSpec.Platform = .macOS

    @Option(name: .long, help: "Bundle identifier, e.g. com.example.App.")
    var bundleId: String?

    @Option(name: .long, help: "Minimum deployment target, e.g. 15.0.")
    var deploymentTarget: String?

    @Option(name: .long, help: "Host app target for a unit test bundle.")
    var testHost: String?

    func run() throws {
        try runCommand(json: options.json) {
            let project = try options.loadProject()
            let spec = TargetSpec(
                name: name, productType: type, platform: platform,
                bundleIdentifier: bundleId, deploymentTarget: deploymentTarget,
                testHostTarget: testHost)
            let result = try project.addTarget(spec)
            try MutationRunner.finish(
                action: "add-target", project: project,
                operation: result, options: options, mutation: mutation)
        }
    }
}

struct AddDependency: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dependency",
        abstract: "Make one target depend on another."
    )

    @OptionGroup var options: GlobalOptions
    @OptionGroup var mutation: MutationOptions

    @Option(name: .long, help: "The dependent target.")
    var target: String

    @Option(name: .long, help: "The target to depend on.")
    var on: String

    func run() throws {
        try runCommand(json: options.json) {
            let project = try options.loadProject()
            let result = try project.addDependency(target: target, on: on)
            try MutationRunner.finish(
                action: "add-dependency", project: project,
                operation: result, options: options, mutation: mutation)
        }
    }
}

struct AddPackage: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "package",
        abstract: "Add a Swift package dependency and link a product into a target."
    )

    @OptionGroup var options: GlobalOptions
    @OptionGroup var mutation: MutationOptions

    @Argument(help: "Repository URL (remote) or relative path (--local).")
    var location: String

    @Flag(name: .long, help: "Treat `location` as a relative path to a local package.")
    var local = false

    @Option(name: .long, help: "Product name to link.")
    var product: String

    @Option(name: .long, help: "Target to link the product into.")
    var target: String

    @Option(name: .long, help: "Version requirement: 'upToNextMajor:1.2.0', 'upToNextMinor:1.2.0', 'exact:1.2.0', 'branch:main', 'revision:<sha>', 'range:1.0.0:2.0.0'. Ignored for --local.")
    var requirement: String = "upToNextMajor:1.0.0"

    func run() throws {
        try runCommand(json: options.json) {
            let project = try options.loadProject()
            let result: OperationResult
            if local {
                result = try project.addLocalPackage(path: location, product: product, target: target)
            } else {
                result = try project.addRemotePackage(
                    url: location, requirement: try parseRequirement(requirement),
                    product: product, target: target)
            }
            try MutationRunner.finish(
                action: "add-package", project: project,
                operation: result, options: options, mutation: mutation)
        }
    }

    private func parseRequirement(_ raw: String) throws -> PackageRequirement {
        let parts = raw.split(separator: ":", maxSplits: 2).map(String.init)
        switch parts.first {
        case "upToNextMajor": return .upToNextMajor(parts[1])
        case "upToNextMinor": return .upToNextMinor(parts[1])
        case "exact": return .exact(parts[1])
        case "branch": return .branch(parts[1])
        case "revision": return .revision(parts[1])
        case "range" where parts.count == 3: return .range(from: parts[1], to: parts[2])
        default:
            throw ProjectorError.invalidOperation("Unrecognized version requirement: \(raw)")
        }
    }
}

extension TargetSpec.ProductType: ExpressibleByArgument {}
extension TargetSpec.Platform: ExpressibleByArgument {}
