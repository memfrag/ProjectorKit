import Foundation

/// Result of an opt-in `xcodebuild -list` sanity check after a write.
public struct XcodebuildVerification: Sendable {
    public let succeeded: Bool
    public let output: String
}

public enum SanityChecks {
    /// Runs `xcodebuild -list -project <path> -json` and reports whether it
    /// succeeded. This is the ground-truth check that Xcode itself accepts the
    /// written project — deliberately opt-in, since it spawns XCBBuildService
    /// and can fail for reasons unrelated to the edit (DerivedData state,
    /// licensing prompts, environment).
    public static func verifyWithXcodebuild(projectPath: URL) -> XcodebuildVerification {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = ["-list", "-project", projectPath.path, "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return XcodebuildVerification(succeeded: process.terminationStatus == 0, output: output)
        } catch {
            return XcodebuildVerification(succeeded: false, output: "failed to launch xcodebuild: \(error)")
        }
    }
}
