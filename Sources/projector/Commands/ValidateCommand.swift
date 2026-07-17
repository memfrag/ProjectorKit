import ArgumentParser
import Foundation
import ProjectorKit

struct ValidateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Check the project for structural problems."
    )

    @OptionGroup var options: GlobalOptions

    struct Payload: Encodable {
        let issues: [ValidationIssue]
        let valid: Bool
    }

    func run() throws {
        try runCommand(json: options.json) {
            let project = try options.loadProject()
            let issues = ProjectValidator(project: project).validate()
            let hasErrors = issues.contains { $0.severity == .error }

            try emit(action: "validate", json: options.json,
                     payload: Payload(issues: issues, valid: !hasErrors)) {
                if issues.isEmpty { return "Project is valid." }
                return issues.map { "\($0.description)" }.joined(separator: "\n")
            }

            // The payload already reports the failure; signal it via exit code
            // without emitting a second error envelope.
            if hasErrors {
                throw ExitCode(ProjectorExitCode.validationFailed)
            }
        }
    }
}
