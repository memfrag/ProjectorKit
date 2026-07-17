import ArgumentParser
import Foundation
import ProjectorKit

@main
struct Projector: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "projector",
        abstract: "Reliably inspect and manipulate Xcode project files.",
        discussion: """
        Designed for scripts and agents: structured --json output, stable exit \
        codes, idempotent mutations, and minimal-diff writes.
        """,
        version: "0.1.0",
        subcommands: [
            ListCommand.self,
            ShowCommand.self,
            GetCommand.self,
            ValidateCommand.self,
        ]
    )
}

enum ProjectorExitCode {
    static let success: Int32 = 0
    static let checkFoundChanges: Int32 = 2
    static let notFound: Int32 = 3
    static let validationFailed: Int32 = 4
    static let parseError: Int32 = 5
    static let writeError: Int32 = 6

    static func code(for error: ProjectorError) -> Int32 {
        switch error {
        case .notFound: notFound
        case .validationFailed: validationFailed
        case .projectNotFound, .parseFailure, .unsupportedObjectVersion: parseError
        case .concurrentModification, .writeFailure: writeError
        case .invalidOperation: notFound
        }
    }
}

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Path to the .xcodeproj. Inferred when exactly one exists in the current directory.")
    var project: String?

    @Flag(name: .long, help: "Emit structured JSON output.")
    var json = false

    func resolveProjectPath() throws -> URL {
        if let project {
            return URL(fileURLWithPath: project)
        }
        let cwd = FileManager.default.currentDirectoryPath
        let entries = try FileManager.default.contentsOfDirectory(atPath: cwd)
        let candidates = entries.filter { $0.hasSuffix(".xcodeproj") }
        switch candidates.count {
        case 1:
            return URL(fileURLWithPath: cwd).appendingPathComponent(candidates[0])
        case 0:
            throw ProjectorError.projectNotFound(path: "\(cwd) (no .xcodeproj found; pass --project)")
        default:
            throw ProjectorError.invalidOperation(
                "Multiple .xcodeproj found in \(cwd): \(candidates.sorted().joined(separator: ", ")). Pass --project.")
        }
    }

    func loadProject() throws -> ProjectorProject {
        try ProjectorProject.load(at: resolveProjectPath())
    }
}

/// Runs a command body, mapping ProjectorError to stable exit codes and
/// rendering errors as JSON when requested.
func runCommand(json: Bool, _ body: () throws -> Void) throws {
    do {
        try body()
    } catch let error as ProjectorError {
        if json {
            let envelope: [String: Any] = [
                "ok": false,
                "error": error.description,
                "schemaVersion": 1,
            ]
            let data = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8)!)
        } else {
            FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
        }
        throw ExitCode(ProjectorExitCode.code(for: error))
    }
}
