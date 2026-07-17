import ArgumentParser
import Foundation
import ProjectorKit

struct GetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Read a single value.",
        subcommands: [GetBuildSetting.self]
    )
}

struct GetBuildSetting: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-setting",
        abstract: "Read a build setting, per configuration."
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Build setting key, e.g. SWIFT_VERSION.")
    var key: String

    @Option(name: .long, help: "Target name. Omit to read project-level settings.")
    var target: String?

    @Option(name: .long, help: "Only this configuration (e.g. Debug).")
    var configuration: String?

    @Flag(name: .long, help: "Resolve through target/project/xcconfig layers instead of reading only the literal target dictionary.")
    var resolved = false

    struct Payload: Encodable {
        let key: String
        let target: String?
        let values: [BuildSettingResolver.ResolvedValue]
    }

    func run() throws {
        try runCommand(json: options.json) {
            let project = try options.loadProject()
            let resolver = BuildSettingResolver(project: project)
            var values: [BuildSettingResolver.ResolvedValue]
            if let target {
                values = try resolver.resolve(key: key, target: target)
                if !resolved {
                    // Literal target-level only: drop values that came from
                    // fallback layers.
                    values = values.map { value in
                        value.origin == .target ? value
                            : .init(configuration: value.configuration, value: nil, origin: nil)
                    }
                }
            } else {
                values = try resolver.projectValues(key: key)
            }
            if let configuration {
                values = values.filter { $0.configuration == configuration }
            }
            try emit(action: "get-build-setting", json: options.json,
                     payload: Payload(key: key, target: target, values: values)) {
                values.map { value in
                    let shown = value.value ?? "(unset)"
                    let origin = value.origin.map { " [\($0.rawValue)]" } ?? ""
                    return "\(value.configuration)\t\(shown)\(origin)"
                }.joined(separator: "\n")
            }
        }
    }
}
