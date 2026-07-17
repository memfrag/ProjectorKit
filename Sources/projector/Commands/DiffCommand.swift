import ArgumentParser
import Foundation
import ProjectorKit

struct DiffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Show the pending change the current in-memory edits would write (normally empty; useful after scripted edits)."
    )

    @OptionGroup var options: GlobalOptions

    struct Payload: Encodable {
        let fidelity: String
        let hasChanges: Bool
        let diff: String
    }

    func run() throws {
        try runCommand(json: options.json) {
            let project = try options.loadProject()
            let check = try project.check()
            try emit(action: "diff", json: options.json,
                     payload: Payload(fidelity: check.fidelity.rawValue,
                                      hasChanges: check.hasChanges,
                                      diff: check.diff.unified())) {
                check.hasChanges ? check.diff.unified() : "(no pending changes)"
            }
        }
    }
}
