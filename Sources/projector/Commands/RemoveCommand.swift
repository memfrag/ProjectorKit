import ArgumentParser
import Foundation
import ProjectorKit

struct RemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove an entity from the project.",
        subcommands: [
            RemoveFile.self, RemoveTarget.self, RemoveDependency.self, RemovePackage.self,
        ]
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

struct RemoveTarget: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "target", abstract: "Remove a target.")

    @OptionGroup var options: GlobalOptions
    @OptionGroup var mutation: MutationOptions

    @Argument(help: "Target name.")
    var name: String

    func run() throws {
        try runCommand(json: options.json) {
            let project = try options.loadProject()
            let result = try project.removeTarget(name)
            try MutationRunner.finish(
                action: "remove-target", project: project,
                operation: result, options: options, mutation: mutation)
        }
    }
}

struct RemoveDependency: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dependency", abstract: "Remove a target dependency.")

    @OptionGroup var options: GlobalOptions
    @OptionGroup var mutation: MutationOptions

    @Option(name: .long, help: "The dependent target.")
    var target: String

    @Option(name: .long, help: "The target to stop depending on.")
    var on: String

    func run() throws {
        try runCommand(json: options.json) {
            let project = try options.loadProject()
            let result = try project.removeDependency(target: target, on: on)
            try MutationRunner.finish(
                action: "remove-dependency", project: project,
                operation: result, options: options, mutation: mutation)
        }
    }
}

struct RemovePackage: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "package", abstract: "Remove a Swift package reference and unlink its products.")

    @OptionGroup var options: GlobalOptions
    @OptionGroup var mutation: MutationOptions

    @Argument(help: "Repository URL or local relative path.")
    var location: String

    func run() throws {
        try runCommand(json: options.json) {
            let project = try options.loadProject()
            let result = try project.removePackage(urlOrPath: location)
            try MutationRunner.finish(
                action: "remove-package", project: project,
                operation: result, options: options, mutation: mutation)
        }
    }
}
