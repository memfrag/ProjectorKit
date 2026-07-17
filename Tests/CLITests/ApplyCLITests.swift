import Foundation
import Testing

@Suite struct ApplyCLITests {
    @Test func applyBatchAddsFileAndSetsBuildSetting() throws {
        let projectDir = try freshSyncedAppCopy()
        try "let x = 1\n".write(
            to: projectDir.appendingPathComponent("Helper.swift"), atomically: true, encoding: .utf8)

        let ops = """
        [
          {"op": "add-file", "path": "Helper.swift", "targets": ["SyncedApp"], "group": "Shared"},
          {"op": "set-build-setting", "key": "SWIFT_VERSION", "value": "6.0", "target": "SyncedApp"}
        ]
        """
        let opsFile = projectDir.appendingPathComponent("ops.json")
        try ops.write(to: opsFile, atomically: true, encoding: .utf8)

        let result = try runCLI(
            ["apply", "ops.json", "--project", "SyncedApp.xcodeproj", "--json"], in: projectDir)
        #expect(result.exitCode == 0, "stderr: \(result.stderr)")
        #expect(result.stdout.contains("\"applied\""))

        // Re-running is fully idempotent.
        let second = try runCLI(
            ["apply", "ops.json", "--project", "SyncedApp.xcodeproj", "--json"], in: projectDir)
        #expect(second.exitCode == 0)
        #expect(second.stdout.contains("\"already-satisfied\""))
    }

    @Test func applyBatchCheckReportsChangesWithoutWriting() throws {
        let projectDir = try freshSyncedAppCopy()
        let ops = #"[{"op": "set-build-setting", "key": "SWIFT_VERSION", "value": "6.0", "target": "SyncedApp"}]"#
        let opsFile = projectDir.appendingPathComponent("ops.json")
        try ops.write(to: opsFile, atomically: true, encoding: .utf8)

        let result = try runCLI(
            ["apply", "ops.json", "--project", "SyncedApp.xcodeproj", "--check"], in: projectDir)
        #expect(result.exitCode == 2)
        #expect(result.stdout.contains("SWIFT_VERSION"))

        // Nothing was written.
        let pbxproj = try String(
            contentsOf: projectDir.appendingPathComponent("SyncedApp.xcodeproj/project.pbxproj"), encoding: .utf8)
        #expect(pbxproj.contains("SWIFT_VERSION = 5.0"))
    }

    @Test func applyBatchUnknownOpFailsWithoutPartialWrite() throws {
        let projectDir = try freshSyncedAppCopy()
        let original = try String(
            contentsOf: projectDir.appendingPathComponent("SyncedApp.xcodeproj/project.pbxproj"), encoding: .utf8)

        let ops = """
        [
          {"op": "set-build-setting", "key": "SWIFT_VERSION", "value": "6.0", "target": "SyncedApp"},
          {"op": "not-a-real-op"}
        ]
        """
        let opsFile = projectDir.appendingPathComponent("ops.json")
        try ops.write(to: opsFile, atomically: true, encoding: .utf8)

        let result = try runCLI(["apply", "ops.json", "--project", "SyncedApp.xcodeproj"], in: projectDir)
        #expect(result.exitCode != 0)

        let after = try String(
            contentsOf: projectDir.appendingPathComponent("SyncedApp.xcodeproj/project.pbxproj"), encoding: .utf8)
        #expect(after == original, "an operation failing mid-batch must not leave a partial write")
    }
}
