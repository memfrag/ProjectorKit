import ArgumentParser
import Foundation
import ProjectorKit

struct RemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove an entity from the project.",
        subcommands: [RemoveFile.self]
    )
}

struct RemoveFile: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "file",
        abstract: "Remove a file from the project."
    )

    @OptionGroup var options: GlobalOptions
    @OptionGroup var mutation: MutationOptions

    @Argument(help: "Path to the file, relative to the project directory (or absolute).")
    var path: String

    @Flag(name: .long, help: "Also delete the file from disk.")
    var delete = false

    func run() throws {
        try runCommand(json: options.json) {
            let project = try options.loadProject()
            let result = try project.removeFile(at: path, deleteFromDisk: delete)
            try MutationRunner.finish(
                action: "remove-file", project: project,
                operation: result, options: options, mutation: mutation)
        }
    }
}
