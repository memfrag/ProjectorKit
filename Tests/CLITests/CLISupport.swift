import Foundation

/// Package root, resolved at compile time from this file's own path so tests
/// don't depend on the working directory `swift test` happens to use.
let packageRoot: URL = {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // CLISupport.swift -> CLITests/
        .deletingLastPathComponent() // CLITests/ -> Tests/
        .deletingLastPathComponent() // Tests/ -> package root
}()

let projectorBinary = packageRoot.appendingPathComponent(".build/debug/projector")

let syncedAppFixture = packageRoot.appendingPathComponent("Tests/ProjectorKitTests/Fixtures/SyncedApp")

struct CLIResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Runs the built `projector` binary with the given arguments and working
/// directory, capturing output.
func runCLI(_ arguments: [String], in directory: URL) throws -> CLIResult {
    let process = Process()
    process.executableURL = projectorBinary
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()
    process.waitUntilExit()
    let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return CLIResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
}

/// Copies the SyncedApp fixture to a fresh temp directory and returns its URL.
func freshSyncedAppCopy() throws -> URL {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("projector-cli-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let destination = scratch.appendingPathComponent("SyncedApp")
    try FileManager.default.copyItem(at: syncedAppFixture, to: destination)
    return destination
}
