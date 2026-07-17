import ArgumentParser
import Foundation
import ProjectorKit

struct SetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set a value in the project.",
        subcommands: [SetBuildSetting.self, SetXCConfig.self, SetXCConfigValue.self]
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

struct SetXCConfig: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcconfig",
        abstract: "Attach an .xcconfig file as the base configuration for the project or a target."
    )

    @OptionGroup var options: GlobalOptions
    @OptionGroup var mutation: MutationOptions

    @Argument(help: "Path to the .xcconfig file, relative to the project directory.")
    var path: String

    @Option(name: .long, help: "Target name. Omit to set at the project level.")
    var target: String?

    @Option(name: .long, help: "Only this configuration (e.g. Debug). Omit for all.")
    var configuration: String?

    func run() throws {
        try runCommand(json: options.json) {
            let project = try options.loadProject()
            let scope: SettingScope = target.map { .target($0, configuration: configuration) }
                ?? .project(configuration: configuration)
            let result = try project.setXCConfig(path, scope: scope)
            try MutationRunner.finish(
                action: "set-xcconfig", project: project,
                operation: result, options: options, mutation: mutation)
        }
    }
}

struct SetXCConfigValue: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcconfig-value",
        abstract: "Set a key in an .xcconfig file's own text, preserving comments and formatting elsewhere in the file."
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .long, help: "Path to the .xcconfig file, relative to the project directory.")
    var file: String

    @Argument(help: "Setting key, e.g. SWIFT_VERSION.")
    var key: String

    @Argument(help: "Value.")
    var value: String

    @Flag(name: .long, help: "Preview the change without writing.")
    var check = false

    @Flag(name: .long, help: "Do not write a .projector-backup sibling before saving.")
    var noBackup = false

    struct Payload: Encodable {
        let result: String
        let diff: String?
    }

    func run() throws {
        try runCommand(json: options.json) {
            let project = try options.loadProject()
            let sourceRoot = project.xcodeprojPath.deletingLastPathComponent()
            let url = file.hasPrefix("/") ? URL(fileURLWithPath: file) : sourceRoot.appendingPathComponent(file)
            let plan = try XCConfigEditor.plan(setting: key, to: value, in: url)

            if check {
                let payload = Payload(result: plan.hasChanges ? "would-apply" : "no-change", diff: plan.diff.unified())
                try emit(action: "set-xcconfig-value", json: options.json, payload: payload) {
                    plan.hasChanges ? plan.diff.unified() : "(no pending changes)"
                }
                if plan.hasChanges { throw ExitCode(ProjectorExitCode.checkFoundChanges) }
                return
            }

            try XCConfigEditor.apply(plan, to: url, backup: !noBackup)
            let payload = Payload(result: plan.hasChanges ? "applied" : "already-satisfied", diff: nil)
            try emit(action: "set-xcconfig-value", json: options.json, payload: payload) {
                "set-xcconfig-value: \(payload.result)"
            }
        }
    }
}
