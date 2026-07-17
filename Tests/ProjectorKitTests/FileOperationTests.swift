import Foundation
import Testing
import XcodeProj
@testable import ProjectorKit

@Suite struct FileOperationTests {
    /// Adding a classic file into the (empty, classic) main group creates a file
    /// reference and wires it into the target's Sources phase.
    @Test func addClassicSourceFileWiresIntoSourcesPhase() throws {
        let projectURL = try temporaryFixture("SyncedApp", project: "SyncedApp.xcodeproj")
        let sourceRoot = projectURL.deletingLastPathComponent()
        // A file NOT under the synchronized SyncedApp/ folder → classic routing.
        try "let x = 1\n".write(to: sourceRoot.appendingPathComponent("Helper.swift"),
                               atomically: true, encoding: .utf8)

        let project = try ProjectorProject.load(at: projectURL)
        let result = try project.addFile(at: "Helper.swift", toTargets: ["SyncedApp"], group: "Shared")
        #expect(result.isApplied)
        let outcome = try project.save()
        #expect(outcome.fidelity == .surgical)

        let reloaded = try ProjectorProject.load(at: projectURL)
        let files = try Inspector(project: reloaded).fileSnapshots()
        let helper = try #require(files.first { $0.path == "Shared/Helper.swift" || $0.path == "Helper.swift" })
        #expect(helper.targets == ["SyncedApp"])
        #expect(!helper.synchronized)
    }

    /// Adding a file twice is idempotent.
    @Test func addFileIsIdempotent() throws {
        let projectURL = try temporaryFixture("SyncedApp", project: "SyncedApp.xcodeproj")
        let sourceRoot = projectURL.deletingLastPathComponent()
        try "let x = 1\n".write(to: sourceRoot.appendingPathComponent("Helper.swift"),
                               atomically: true, encoding: .utf8)

        let project = try ProjectorProject.load(at: projectURL)
        _ = try project.addFile(at: "Helper.swift", toTargets: ["SyncedApp"])
        try project.save()

        let again = try ProjectorProject.load(at: projectURL)
        let result = try again.addFile(at: "Helper.swift", toTargets: ["SyncedApp"])
        #expect(result == .alreadySatisfied)
    }

    /// A file already inside a synchronized root, added to its owning target, is
    /// implicit membership — no pbxproj change at all.
    @Test func addFileInSynchronizedRootForOwnerIsNoOp() throws {
        let projectURL = try temporaryFixture("SyncedApp", project: "SyncedApp.xcodeproj")
        let project = try ProjectorProject.load(at: projectURL)
        // SyncedAppApp.swift lives under the synchronized SyncedApp/ folder,
        // which the SyncedApp target owns.
        let result = try project.addFile(at: "SyncedApp/SyncedAppApp.swift", toTargets: ["SyncedApp"])
        #expect(result == .alreadySatisfied)
        let check = try project.check()
        #expect(!check.hasChanges)
    }

    /// Removing a classic file drops its reference and build file.
    @Test func removeClassicFile() throws {
        let projectURL = try temporaryFixture("SyncedApp", project: "SyncedApp.xcodeproj")
        let sourceRoot = projectURL.deletingLastPathComponent()
        try "let x = 1\n".write(to: sourceRoot.appendingPathComponent("Helper.swift"),
                               atomically: true, encoding: .utf8)

        let project = try ProjectorProject.load(at: projectURL)
        _ = try project.addFile(at: "Helper.swift", toTargets: ["SyncedApp"])
        try project.save()

        let removing = try ProjectorProject.load(at: projectURL)
        let result = try removing.removeFile(at: "Helper.swift")
        #expect(result.isApplied)
        try removing.save()

        let reloaded = try ProjectorProject.load(at: projectURL)
        let files = try Inspector(project: reloaded).fileSnapshots()
        #expect(!files.contains { $0.path.hasSuffix("Helper.swift") })
    }
}
