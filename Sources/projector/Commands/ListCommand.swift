import ArgumentParser
import Foundation
import ProjectorKit
import XcodeProj

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List entities in the project.",
        subcommands: [
            ListTargets.self, ListFiles.self, ListGroups.self,
            ListConfigurations.self, ListSchemes.self, ListPackages.self,
            ListBuildPhases.self,
        ],
        defaultSubcommand: ListTargets.self
    )
}

struct ListTargets: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "targets", abstract: "List all targets.")

    @OptionGroup var options: GlobalOptions

    struct Payload: Encodable {
        let targets: [TargetSnapshot]
    }

    func run() throws {
        try runCommand(json: options.json) {
            let project = try options.loadProject()
            let inspector = Inspector(project: project)
            let targets = try project.targets.map { try inspector.targetSnapshot($0) }
            try emit(action: "list-targets", json: options.json, payload: Payload(targets: targets)) {
                targets.map { "\($0.name)\t\($0.productType)" }.joined(separator: "\n")
            }
        }
    }
}

struct ListFiles: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "files", abstract: "List files with target membership.")

    @OptionGroup var options: GlobalOptions

    @Option(name: .long, help: "Only files belonging to this target.")
    var target: String?

    struct Payload: Encodable {
        let files: [FileSnapshot]
    }

    func run() throws {
        try runCommand(json: options.json) {
            let project = try options.loadProject()
            if let target { _ = try project.target(named: target) }
            var files = try Inspector(project: project).fileSnapshots()
            if let target {
                files = files.filter { $0.targets.contains(target) }
            }
            try emit(action: "list-files", json: options.json, payload: Payload(files: files)) {
                files.map { file in
                    let marker = file.synchronized ? " (synced)" : ""
                    return "\(file.path)\t[\(file.targets.joined(separator: ", "))]\(marker)"
                }.joined(separator: "\n")
            }
        }
    }
}

struct ListGroups: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "groups", abstract: "List the navigator group tree.")

    @OptionGroup var options: GlobalOptions

    struct GroupEntry: Encodable {
        let path: String
        /// "group" or "synchronized"
        let kind: String
    }

    struct Payload: Encodable {
        let groups: [GroupEntry]
    }

    func run() throws {
        try runCommand(json: options.json) {
            let project = try options.loadProject()
            let root = try project.rootProject
            var entries: [GroupEntry] = []

            func walk(_ element: PBXFileElement, prefix: String) {
                let display = element.name ?? element.path ?? ""
                let current = prefix.isEmpty ? display : "\(prefix)/\(display)"
                switch element {
                case is PBXFileSystemSynchronizedRootGroup:
                    entries.append(GroupEntry(path: current, kind: "synchronized"))
                case let group as PBXGroup:
                    if !current.isEmpty {
                        entries.append(GroupEntry(path: current, kind: "group"))
                    }
                    for child in group.children where !(child is PBXFileReference) {
                        walk(child, prefix: current)
                    }
                default:
                    break
                }
            }
            if let main = root.mainGroup { walk(main, prefix: "") }

            try emit(action: "list-groups", json: options.json, payload: Payload(groups: entries)) {
                entries.map { "\($0.path)\t(\($0.kind))" }.joined(separator: "\n")
            }
        }
    }
}

struct ListConfigurations: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "configurations", abstract: "List build configurations.")

    @OptionGroup var options: GlobalOptions

    struct Payload: Encodable {
        let configurations: [String]
    }

    func run() throws {
        try runCommand(json: options.json) {
            let project = try options.loadProject()
            let names = try project.rootProject.buildConfigurationList.buildConfigurations.map(\.name)
            try emit(action: "list-configurations", json: options.json, payload: Payload(configurations: names)) {
                names.joined(separator: "\n")
            }
        }
    }
}

struct ListSchemes: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "schemes", abstract: "List shared schemes.")

    @OptionGroup var options: GlobalOptions

    struct Payload: Encodable {
        let sharedSchemes: [String]
    }

    func run() throws {
        try runCommand(json: options.json) {
            let project = try options.loadProject()
            let names = project.xcodeProj.sharedData?.schemes.map(\.name).sorted() ?? []
            try emit(action: "list-schemes", json: options.json, payload: Payload(sharedSchemes: names)) {
                names.isEmpty ? "(no shared schemes; Xcode auto-generates one per target)" : names.joined(separator: "\n")
            }
        }
    }
}

struct ListPackages: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "packages", abstract: "List Swift package references.")

    @OptionGroup var options: GlobalOptions

    struct Payload: Encodable {
        let packages: [PackageSnapshot]
    }

    func run() throws {
        try runCommand(json: options.json) {
            let project = try options.loadProject()
            let packages = try Inspector(project: project).packageSnapshots(root: project.rootProject)
            try emit(action: "list-packages", json: options.json, payload: Payload(packages: packages)) {
                packages.map { package in
                    let products = package.products.map(\.name).joined(separator: ", ")
                    return "\(package.location)\t\(package.kind)\t\(package.requirement ?? "")\t[\(products)]"
                }.joined(separator: "\n")
            }
        }
    }
}

struct ListBuildPhases: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "build-phases", abstract: "List a target's build phases.")

    @OptionGroup var options: GlobalOptions

    @Option(name: .long, help: "Target name.")
    var target: String

    struct Payload: Encodable {
        let target: String
        let buildPhases: [BuildPhaseSnapshot]
    }

    func run() throws {
        try runCommand(json: options.json) {
            let project = try options.loadProject()
            let snapshot = try Inspector(project: project).targetSnapshot(project.target(named: target))
            try emit(
                action: "list-build-phases", json: options.json,
                payload: Payload(target: target, buildPhases: snapshot.buildPhases)
            ) {
                snapshot.buildPhases.map { phase in
                    "\(phase.kind)\(phase.name.map { " (\($0))" } ?? "")\t\(phase.files.count) file(s)"
                }.joined(separator: "\n")
            }
        }
    }
}
