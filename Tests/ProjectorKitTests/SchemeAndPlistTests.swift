import Foundation
import Testing
import XcodeProj
@testable import ProjectorKit

@Suite struct SchemeAndPlistTests {
    // MARK: - Schemes

    @Test func addSchemeWritesNewFileAndIsIdempotent() throws {
        let projectURL = try temporaryFixture("SyncedApp", project: "SyncedApp.xcodeproj")
        let project = try ProjectorProject.load(at: projectURL)

        let plan = try project.planScheme(SchemeSpec(name: "SyncedApp-CI", targetName: "SyncedApp"))
        #expect(plan.hasChanges)
        #expect(plan.originalText.isEmpty)
        #expect(plan.newText.contains("BuildableName = \"SyncedApp.app\""))
        try project.applyScheme(plan)

        let schemePath = projectURL.appendingPathComponent("xcshareddata/xcschemes/SyncedApp-CI.xcscheme")
        #expect(FileManager.default.fileExists(atPath: schemePath.path))
        // Written XML re-parses as a valid scheme.
        _ = try XCScheme(pathString: schemePath.path)

        // Idempotent: re-planning the same name (now on disk) reports no changes.
        let reloaded = try ProjectorProject.load(at: projectURL)
        let second = try reloaded.planScheme(SchemeSpec(name: "SyncedApp-CI", targetName: "SyncedApp"))
        #expect(!second.hasChanges)
    }

    @Test func addSchemeWithTestTargetIncludesTestable() throws {
        let projectURL = try temporaryFixture("SyncedApp", project: "SyncedApp.xcodeproj")
        let project = try ProjectorProject.load(at: projectURL)
        _ = try project.addTarget(TargetSpec(name: "SyncedAppTests", productType: .unitTestBundle, testHostTarget: "SyncedApp"))

        let plan = try project.planScheme(SchemeSpec(name: "SyncedApp", targetName: "SyncedApp", testTargetNames: ["SyncedAppTests"]))
        #expect(plan.newText.contains("<Testables>"))
        #expect(plan.newText.contains("BlueprintName = \"SyncedAppTests\""))
    }

    // MARK: - Info.plist (generated)

    @Test func setInfoPlistValueOnGeneratedTargetRoutesToBuildSetting() throws {
        let projectURL = try temporaryFixture("SyncedApp", project: "SyncedApp.xcodeproj")
        let project = try ProjectorProject.load(at: projectURL)

        // The SyncedApp fixture target has GENERATE_INFOPLIST_FILE = YES.
        let result = try project.setInfoPlistValue("CFBundleDisplayName", to: .string("Synced"), target: "SyncedApp")
        #expect(result.isApplied)
        let outcome = try project.save()
        #expect(outcome.fidelity == .surgical)

        let reloaded = try ProjectorProject.load(at: projectURL)
        let value = try BuildSettingResolver(project: reloaded)
            .resolve(key: "INFOPLIST_KEY_CFBundleDisplayName", target: "SyncedApp")
            .first?.value
        #expect(value == "Synced")
    }

    @Test func setInfoPlistIntegerOnGeneratedTargetThrows() throws {
        let projectURL = try temporaryFixture("SyncedApp", project: "SyncedApp.xcodeproj")
        let project = try ProjectorProject.load(at: projectURL)
        #expect(throws: ProjectorError.self) {
            try project.setInfoPlistValue("SomeCount", to: .integer(3), target: "SyncedApp")
        }
    }

    // MARK: - Entitlements (physical file)

    @Test func setEntitlementEditsPhysicalFilePreservingOtherKeys() throws {
        let projectURL = try temporaryFixture("SyncedApp", project: "SyncedApp.xcodeproj")
        let project = try ProjectorProject.load(at: projectURL)

        let result = try project.setEntitlement("com.apple.security.network.client", to: .bool(true), target: "SyncedApp")
        #expect(result.isApplied)

        let entitlementsURL = projectURL.deletingLastPathComponent()
            .appendingPathComponent("SyncedApp/SyncedApp.entitlements")
        let dict = ProjectorProject.readPlistDictionary(at: entitlementsURL)
        // Original keys from the fixture survive.
        #expect(dict["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(dict["com.apple.security.files.user-selected.read-only"] as? Bool == true)
        // New key was added.
        #expect(dict["com.apple.security.network.client"] as? Bool == true)

        // Idempotent.
        let again = try ProjectorProject.load(at: projectURL)
        let repeatResult = try again.setEntitlement("com.apple.security.network.client", to: .bool(true), target: "SyncedApp")
        #expect(repeatResult == .alreadySatisfied)
    }

    @Test func missingEntitlementsSettingThrowsWithGuidance() throws {
        let projectURL = try temporaryFixture("SyncedApp", project: "SyncedApp.xcodeproj")
        let project = try ProjectorProject.load(at: projectURL)
        _ = try project.addTarget(TargetSpec(name: "Tool", productType: .commandLineTool))
        #expect(throws: ProjectorError.self) {
            try project.setEntitlement("com.apple.security.app-sandbox", to: .bool(true), target: "Tool")
        }
    }
}
