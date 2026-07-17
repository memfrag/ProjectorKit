import ArgumentParser
import Foundation
import ProjectorKit

struct SetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set a value in the project.",
        subcommands: [
            SetBuildSetting.self, SetXCConfig.self, SetXCConfigValue.self,
            SetPlist.self, SetEntitlement.self,
        ]
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

/// `set plist`/`set entitlement` route to one of two different write
/// mechanisms depending on the target's configuration (an INFOPLIST_KEY_*
/// pbxproj build setting, or a direct edit of a physical plist file on disk),
/// decided inside ProjectorKit. The physical-file path writes immediately and
/// has no meaningful dry-run, so unlike other mutating commands these do not
/// support --check.
private func runPlistMutation(
    action: String, options: GlobalOptions, apply: (ProjectorProject) throws -> OperationResult
) throws {
    try runCommand(json: options.json) {
        let project = try options.loadProject()
        let result = try apply(project)
        // Only the INFOPLIST_KEY_* routed path touches the pbxproj graph;
        // save() is a no-op (fidelity .none) when nothing changed there.
        let outcome = try project.save()
        let report = MutationReport(
            action: action,
            result: result.isApplied ? (outcome.wroteFile ? "applied" : "applied-on-disk") : "already-satisfied",
            changes: result.changes, fidelity: outcome.fidelity.rawValue, diff: nil, warnings: project.warnings)
        if options.json {
            try printJSON(Envelope(action: action, payload: report))
        } else {
            print("\(action): \(report.result) [fidelity: \(report.fidelity)]")
            for change in report.changes { print("  + \(change.detail)") }
        }
    }
}

struct SetPlist: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plist",
        abstract: "Set a top-level key in a target's Info.plist (routes to INFOPLIST_KEY_* when GENERATE_INFOPLIST_FILE=YES)."
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Info.plist key, e.g. CFBundleDisplayName.")
    var key: String

    @Argument(help: "Value. 'true'/'false' become booleans, integers/decimals become numbers, else a string.")
    var value: String

    @Option(name: .long, help: "Target name.")
    var target: String

    func run() throws {
        try runPlistMutation(action: "set-plist", options: options) { project in
            try project.setInfoPlistValue(key, to: .parse(value), target: target)
        }
    }
}

struct SetEntitlement: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "entitlement",
        abstract: "Set a top-level key in a target's .entitlements file."
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Entitlement key, e.g. com.apple.security.app-sandbox.")
    var key: String

    @Argument(help: "Value. 'true'/'false' become booleans, integers/decimals become numbers, else a string.")
    var value: String

    @Option(name: .long, help: "Target name.")
    var target: String

    func run() throws {
        try runPlistMutation(action: "set-entitlement", options: options) { project in
            try project.setEntitlement(key, to: .parse(value), target: target)
        }
    }
}
