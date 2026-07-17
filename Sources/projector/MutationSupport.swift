import ArgumentParser
import Foundation
import ProjectorKit

/// Flags shared by every mutating command.
struct MutationOptions: ParsableArguments {
    @Flag(name: .long, help: "Preview the change without writing. Exit 2 if changes are pending, 0 if already satisfied.")
    var check = false

    @Flag(name: .long, help: "Include the unified diff in the output even when applying.")
    var diff = false

    @Flag(name: .long, help: "Do not write a .projector-backup sibling before saving.")
    var noBackup = false

    @Flag(name: .long, help: "After writing, run 'xcodebuild -list' and fail if it doesn't succeed. Slow; off by default.")
    var verifyXcodebuild = false
}

/// The JSON/human result of a mutating command, wrapping the operation result
/// and the fidelity/diff of the resulting save. `action` is carried alongside
/// for human rendering but supplied to the JSON envelope separately, so it is
/// not part of this payload's own coding keys.
struct MutationReport: Encodable {
    let action: String
    let result: String            // "applied", "already-satisfied", "would-apply", "no-change"
    let changes: [ChangeDescription]
    let fidelity: String
    let diff: String?
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case result, changes, fidelity, diff, warnings
    }
}

enum MutationRunner {
    /// Applies an operation to a loaded project, then either previews (`--check`)
    /// or saves, emitting a stable report and setting the process exit code.
    static func finish(
        action: String,
        project: ProjectorProject,
        operation: OperationResult,
        options: GlobalOptions,
        mutation: MutationOptions
    ) throws {
        let alreadySatisfied = !operation.isApplied

        if mutation.check {
            let check = try project.check()
            let report = MutationReport(
                action: action,
                result: check.hasChanges ? "would-apply" : "no-change",
                changes: operation.changes,
                fidelity: check.fidelity.rawValue,
                diff: (mutation.diff || check.hasChanges) ? check.diff.unified() : nil,
                warnings: project.warnings)
            try render(report, json: options.json)
            if check.hasChanges {
                throw ExitCode(ProjectorExitCode.checkFoundChanges)
            }
            return
        }

        if alreadySatisfied {
            let report = MutationReport(
                action: action, result: "already-satisfied", changes: [],
                fidelity: Fidelity.none.rawValue, diff: nil, warnings: project.warnings)
            try render(report, json: options.json)
            return
        }

        let outcome = try project.save(options: SaveOptions(
            backup: !mutation.noBackup, verifyXcodebuild: mutation.verifyXcodebuild))
        let report = MutationReport(
            action: action,
            result: outcome.wroteFile ? "applied" : "no-change",
            changes: operation.changes,
            fidelity: outcome.fidelity.rawValue,
            diff: mutation.diff ? outcome.diff.unified() : nil,
            warnings: project.warnings)
        try render(report, json: options.json)
    }

    private static func render(_ report: MutationReport, json: Bool) throws {
        if json {
            try printJSON(Envelope(action: report.action, payload: report))
        } else {
            print("\(report.action): \(report.result) [fidelity: \(report.fidelity)]")
            for change in report.changes {
                print("  + \(change.detail)")
            }
            if let diff = report.diff, !diff.isEmpty {
                print(diff)
            }
            for warning in report.warnings {
                print("  warning: \(warning)")
            }
        }
    }
}
