import Foundation
import Testing
@testable import ProjectorKit

@Suite struct InspectTests {
    func loadSyncedApp() throws -> ProjectorProject {
        try ProjectorProject.load(
            at: fixtureURL("SyncedApp").appendingPathComponent("SyncedApp.xcodeproj"))
    }

    @Test func snapshotReportsTargetsAndConfigurations() throws {
        let snapshot = try Inspector(project: loadSyncedApp()).snapshot()
        #expect(snapshot.name == "SyncedApp")
        #expect(snapshot.objectVersion == 77)
        #expect(snapshot.configurations == ["Debug", "Release"])
        #expect(snapshot.targets.count == 1)

        let target = try #require(snapshot.targets.first)
        #expect(target.productType == "com.apple.product-type.application")
        #expect(target.bundleIdentifier == "com.example.SyncedApp")
        #expect(target.synchronizedRoots == ["SyncedApp"])
    }

    @Test func synchronizedFolderFilesAreEnumeratedFromDisk() throws {
        let files = try Inspector(project: loadSyncedApp()).fileSnapshots()
        let paths = files.map(\.path)
        #expect(paths.contains("SyncedApp/SyncedAppApp.swift"))
        #expect(paths.contains("SyncedApp/ContentView.swift"))
        // Asset catalogs are bundle-like: collapsed to a single entry, not
        // recursed into.
        #expect(paths.contains("SyncedApp/Assets.xcassets"))
        #expect(!paths.contains { $0.hasPrefix("SyncedApp/Assets.xcassets/") })

        let appFile = try #require(files.first { $0.path == "SyncedApp/SyncedAppApp.swift" })
        #expect(appFile.synchronized)
        #expect(appFile.targets == ["SyncedApp"])
    }

    @Test func resolvesBuildSettingWithOrigin() throws {
        let resolver = BuildSettingResolver(project: try loadSyncedApp())
        let values = try resolver.resolve(key: "SWIFT_VERSION", target: "SyncedApp")
        #expect(values.count == 2)
        #expect(values.allSatisfy { $0.value == "5.0" && $0.origin == .target })

        // A project-level-only setting is found via the fallback layer.
        let sdk = try resolver.resolve(key: "SDKROOT", target: "SyncedApp")
        #expect(sdk.allSatisfy { $0.value == "macosx" && $0.origin == .project })
    }

    @Test func unknownTargetThrowsNotFound() throws {
        let project = try loadSyncedApp()
        #expect(throws: ProjectorError.self) {
            try Inspector(project: project).targetSnapshot(project.target(named: "Ghost"))
        }
    }

    @Test func cleanProjectValidates() throws {
        let issues = ProjectValidator(project: try loadSyncedApp()).validate()
        #expect(!issues.contains { $0.severity == .error })
    }
}
