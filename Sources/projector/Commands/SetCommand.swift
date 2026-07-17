import ArgumentParser
import Foundation
import ProjectorKit

struct SetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set a value in the project.",
        subcommands: [SetBuildSetting.self]
    )
}

struct SetBuildSetting: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-setting",
        abstract: "Set a build setting on the project or a target."
    )

    @OptionGroup var options: GlobalOptions
    @OptionGroup var mutation: MutationOptions

    @Argument(help: "Build setting key, e.g. SWIFT_VERSION.")
    var key: String

    @Argument(help: "Value. Repeat is not supported here; use a space-joined string for lists.")
    var value: String

    @Option(name: .long, help: "Target name. Omit to set at the project level.")
    var target: String?

    @Option(name: .long, help: "Only this configuration (e.g. Debug). Omit for all.")
    var configuration: String?

    func run() throws {
        try runCommand(json: options.json) {
            let project = try options.loadProject()
            let scope: SettingScope = target.map { .target($0, configuration: configuration) }
                ?? .project(configuration: configuration)
            let result = try project.setBuildSetting(key, to: .string(value), scope: scope)
            try MutationRunner.finish(
                action: "set-build-setting", project: project,
                operation: result, options: options, mutation: mutation)
        }
    }
}
