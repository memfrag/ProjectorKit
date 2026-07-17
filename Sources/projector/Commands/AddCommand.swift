import ArgumentParser
import Foundation
import ProjectorKit

struct AddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add an entity to the project.",
        subcommands: [AddFile.self, AddGroup.self]
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
