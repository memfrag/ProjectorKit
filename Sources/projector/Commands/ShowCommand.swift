import ArgumentParser
import Foundation
import ProjectorKit

struct ShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show details of a single entity.",
        subcommands: [ShowTarget.self, ShowProject.self]
    )
}

struct ShowTarget: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "target", abstract: "Show one target in detail.")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Target name.")
    var name: String

    func run() throws {
        try runCommand(json: options.json) {
            let project = try options.loadProject()
            let snapshot = try Inspector(project: project).targetSnapshot(project.target(named: name))
            try emit(action: "show-target", json: options.json, payload: snapshot) {
                var lines = ["Target: \(snapshot.name)", "  Product type: \(snapshot.productType)"]
                if let bundle = snapshot.bundleIdentifier { lines.append("  Bundle id: \(bundle)") }
                if !snapshot.dependencies.isEmpty {
                    lines.append("  Dependencies: \(snapshot.dependencies.joined(separator: ", "))")
                }
                if !snapshot.packageProducts.isEmpty {
                    lines.append("  Package products: \(snapshot.packageProducts.joined(separator: ", "))")
                }
                if !snapshot.synchronizedRoots.isEmpty {
                    lines.append("  Synchronized folders: \(snapshot.synchronizedRoots.joined(separator: ", "))")
                }
                lines.append("  Build phases:")
                for phase in snapshot.buildPhases {
                    lines.append("    - \(phase.kind)\(phase.name.map { " (\($0))" } ?? "") — \(phase.files.count) file(s)")
                }
                return lines.joined(separator: "\n")
            }
        }
    }
}

struct ShowProject: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "project", abstract: "Show a full project snapshot.")

    @OptionGroup var options: GlobalOptions

    func run() throws {
        try runCommand(json: options.json) {
            let project = try options.loadProject()
            let snapshot = try Inspector(project: project).snapshot()
            try emit(action: "show-project", json: options.json, payload: snapshot) {
                """
                \(snapshot.name) (objectVersion \(snapshot.objectVersion))
                  Configurations: \(snapshot.configurations.joined(separator: ", "))
                  Targets: \(snapshot.targets.map(\.name).joined(separator: ", "))
                  Files: \(snapshot.files.count)
                  Packages: \(snapshot.packages.count)
                  Shared schemes: \(snapshot.sharedSchemes.joined(separator: ", "))
                """
            }
        }
    }
}
