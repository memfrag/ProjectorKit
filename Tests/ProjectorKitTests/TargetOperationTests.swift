import Foundation
import Testing
import XcodeProj
@testable import ProjectorKit

@Suite struct TargetOperationTests {
    @Test func addCommandLineToolTargetAndBuild() throws {
        let projectURL = try temporaryFixture("SyncedApp", project: "SyncedApp.xcodeproj")
        let project = try ProjectorProject.load(at: projectURL)

        let spec = TargetSpec(name: "Tool", productType: .commandLineTool, platform: .macOS)
        let result = try project.addTarget(spec)
        #expect(result.isApplied)
        let outcome = try project.save()
        #expect(outcome.fidelity == .surgical)

        let reloaded = try ProjectorProject.load(at: projectURL)
        #expect(reloaded.targets.map(\.name).contains("Tool"))
        let snapshot = try Inspector(project: reloaded).targetSnapshot(reloaded.target(named: "Tool"))
        #expect(snapshot.productType == "com.apple.product-type.tool")

        // Every generated configuration must set SWIFT_VERSION, or Xcode
        // refuses to compile any Swift source added to the target later.
        let values = try BuildSettingResolver(project: reloaded).resolve(key: "SWIFT_VERSION", target: "Tool")
        #expect(values.allSatisfy { $0.value != nil })
    }

    @Test func addTargetIsIdempotentForMatchingType() throws {
        let projectURL = try temporaryFixture("SyncedApp", project: "SyncedApp.xcodeproj")
        let project = try ProjectorProject.load(at: projectURL)
        let spec = TargetSpec(name: "Tool", productType: .commandLineTool)
        _ = try project.addTarget(spec)
        try project.save()

        let again = try ProjectorProject.load(at: projectURL)
        let result = try again.addTarget(spec)
        #expect(result == .alreadySatisfied)
    }

    @Test func addTargetConflictingTypeThrows() throws {
        let projectURL = try temporaryFixture("SyncedApp", project: "SyncedApp.xcodeproj")
        let project = try ProjectorProject.load(at: projectURL)
        #expect(throws: ProjectorError.self) {
            try project.addTarget(TargetSpec(name: "SyncedApp", productType: .framework))
        }
    }

    @Test func addDependencyWiresProxyAndIsIdempotent() throws {
        let projectURL = try temporaryFixture("SyncedApp", project: "SyncedApp.xcodeproj")
        let project = try ProjectorProject.load(at: projectURL)
        _ = try project.addTarget(TargetSpec(name: "Helper", productType: .staticLibrary))

        let result = try project.addDependency(target: "SyncedApp", on: "Helper")
        #expect(result.isApplied)
        let again = try project.addDependency(target: "SyncedApp", on: "Helper")
        #expect(again == .alreadySatisfied)

        try project.save()
        let reloaded = try ProjectorProject.load(at: projectURL)
        let snapshot = try Inspector(project: reloaded).targetSnapshot(reloaded.target(named: "SyncedApp"))
        #expect(snapshot.dependencies == ["Helper"])
    }

    @Test func selfDependencyThrows() throws {
        let projectURL = try temporaryFixture("SyncedApp", project: "SyncedApp.xcodeproj")
        let project = try ProjectorProject.load(at: projectURL)
        #expect(throws: ProjectorError.self) {
            try project.addDependency(target: "SyncedApp", on: "SyncedApp")
        }
    }

    @Test func addRemotePackageLinksProductAndDedupsReference() throws {
        let projectURL = try temporaryFixture("SyncedApp", project: "SyncedApp.xcodeproj")
        let project = try ProjectorProject.load(at: projectURL)

        let result = try project.addRemotePackage(
            url: "https://github.com/apple/swift-log.git",
            requirement: .upToNextMajor("1.5.0"),
            product: "Logging", target: "SyncedApp")
        #expect(result.isApplied)

        // Adding a second product from the same URL reuses the reference.
        let second = try project.addRemotePackage(
            url: "https://github.com/apple/swift-log.git",
            requirement: .upToNextMajor("1.5.0"),
            product: "LoggingBenchmarks", target: "SyncedApp")
        #expect(second.isApplied)
        #expect(try project.rootProject.remotePackages.count == 1)

        // Re-linking the same product is a no-op.
        let again = try project.addRemotePackage(
            url: "https://github.com/apple/swift-log.git",
            requirement: .upToNextMajor("1.5.0"),
            product: "Logging", target: "SyncedApp")
        #expect(again == .alreadySatisfied)

        let outcome = try project.save()
        #expect(outcome.fidelity == .surgical)

        let reloaded = try ProjectorProject.load(at: projectURL)
        let packages = try Inspector(project: reloaded).packageSnapshots(root: reloaded.rootProject)
        #expect(packages.count == 1)
        #expect(Set(packages[0].products.map(\.name)) == ["Logging", "LoggingBenchmarks"])
    }

    @Test func removePackageUnlinksProducts() throws {
        let projectURL = try temporaryFixture("SyncedApp", project: "SyncedApp.xcodeproj")
        let project = try ProjectorProject.load(at: projectURL)
        _ = try project.addRemotePackage(
            url: "https://github.com/apple/swift-log.git",
            requirement: .upToNextMajor("1.5.0"),
            product: "Logging", target: "SyncedApp")
        try project.save()

        let removing = try ProjectorProject.load(at: projectURL)
        let result = try removing.removePackage(urlOrPath: "https://github.com/apple/swift-log.git")
        #expect(result.isApplied)
        try removing.save()

        let reloaded = try ProjectorProject.load(at: projectURL)
        #expect(try reloaded.rootProject.remotePackages.isEmpty)
    }

    @Test func removeTargetDropsDependenciesOnIt() throws {
        let projectURL = try temporaryFixture("SyncedApp", project: "SyncedApp.xcodeproj")
        let project = try ProjectorProject.load(at: projectURL)
        _ = try project.addTarget(TargetSpec(name: "Helper", productType: .staticLibrary))
        _ = try project.addDependency(target: "SyncedApp", on: "Helper")
        try project.save()

        let removing = try ProjectorProject.load(at: projectURL)
        let result = try removing.removeTarget("Helper")
        #expect(result.isApplied)
        try removing.save()

        let reloaded = try ProjectorProject.load(at: projectURL)
        #expect(!reloaded.targets.map(\.name).contains("Helper"))
        let snapshot = try Inspector(project: reloaded).targetSnapshot(reloaded.target(named: "SyncedApp"))
        #expect(snapshot.dependencies.isEmpty)
    }
}
