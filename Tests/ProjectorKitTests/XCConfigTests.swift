import Foundation
import Testing
@testable import ProjectorKit

@Suite struct XCConfigTests {
    @Test func attachingXCConfigIsSurgicalAndIdempotent() throws {
        let projectURL = try temporaryFixture("SyncedApp", project: "SyncedApp.xcodeproj")
        let sourceRoot = projectURL.deletingLastPathComponent()
        try "SWIFT_STRICT_CONCURRENCY = complete\n".write(
            to: sourceRoot.appendingPathComponent("Shared.xcconfig"), atomically: true, encoding: .utf8)

        let project = try ProjectorProject.load(at: projectURL)
        let result = try project.setXCConfig("Shared.xcconfig", scope: .target("SyncedApp"))
        #expect(result.isApplied)
        let outcome = try project.save()
        #expect(outcome.fidelity == .surgical)

        let again = try ProjectorProject.load(at: projectURL)
        let repeatResult = try again.setXCConfig("Shared.xcconfig", scope: .target("SyncedApp"))
        #expect(repeatResult == .alreadySatisfied)
    }

    // MARK: - Text-preserving xcconfig value edits

    @Test func settingNewKeyAppendsLine() throws {
        let url = URL(fileURLWithPath: "/tmp/projector-xcconfig-test-\(UUID().uuidString).xcconfig")
        defer { try? FileManager.default.removeItem(at: url) }
        try "// header comment\nFOO = 1\n".write(to: url, atomically: true, encoding: .utf8)

        let plan = try XCConfigEditor.plan(setting: "BAR", to: "2", in: url)
        #expect(plan.hasChanges)
        #expect(plan.newText == "// header comment\nFOO = 1\nBAR = 2\n")
    }

    @Test func settingExistingKeyPreservesOtherLines() throws {
        let url = URL(fileURLWithPath: "/tmp/projector-xcconfig-test-\(UUID().uuidString).xcconfig")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = "// a comment Xcode would never write\nFOO = 1\nBAR = old // keep this note\n"
        try original.write(to: url, atomically: true, encoding: .utf8)

        let plan = try XCConfigEditor.plan(setting: "BAR", to: "new", in: url)
        #expect(plan.newText.contains("// a comment Xcode would never write"))
        #expect(plan.newText.contains("FOO = 1"))
        #expect(plan.newText.contains("BAR = new // keep this note"))
        #expect(!plan.newText.contains("BAR = old"))

        // Diff touches only the changed line.
        #expect(plan.diff.added == 1)
        #expect(plan.diff.removed == 1)
    }

    @Test func settingSameValueIsNoOp() throws {
        let url = URL(fileURLWithPath: "/tmp/projector-xcconfig-test-\(UUID().uuidString).xcconfig")
        defer { try? FileManager.default.removeItem(at: url) }
        try "FOO = 1\n".write(to: url, atomically: true, encoding: .utf8)

        let plan = try XCConfigEditor.plan(setting: "FOO", to: "1", in: url)
        #expect(!plan.hasChanges)
    }

    @Test func missingFileIsCreated() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("projector-xcconfig-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("New.xcconfig")
        defer { try? FileManager.default.removeItem(at: dir) }

        let plan = try XCConfigEditor.plan(setting: "FOO", to: "1", in: url)
        #expect(plan.hasChanges)
        try XCConfigEditor.apply(plan, to: url, backup: false)
        #expect(try String(contentsOf: url, encoding: .utf8) == "FOO = 1\n")
    }
}
