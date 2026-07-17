import ArgumentParser
import Foundation
import ProjectorKit
import XcodeProj

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List entities in the project.",
        subcommands: [ListTargets.self],
        defaultSubcommand: ListTargets.self
    )
}

struct ListTargets: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "targets",
        abstract: "List all targets."
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        try runCommand(json: options.json) {
            let project = try options.loadProject()
            let targets = project.targets.map { target in
                [
                    "name": target.name,
                    "productType": (target as? PBXNativeTarget)?.productType?.rawValue ?? "aggregate",
                ]
            }
            if options.json {
                let envelope: [String: Any] = [
                    "ok": true,
                    "action": "list-targets",
                    "targets": targets,
                    "schemaVersion": 1,
                ]
                let data = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
                print(String(data: data, encoding: .utf8)!)
            } else {
                for target in targets {
                    print("\(target["name"] ?? "")\t\(target["productType"] ?? "")")
                }
            }
        }
    }
}
