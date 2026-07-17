import Foundation
import Testing
import XcodeProj
@testable import ProjectorKit

@Suite struct FidelityTests {
    // MARK: - No-op byte identity (golden test #1)

    @Test func noOpSaveIsByteIdentical() throws {
        let projectURL = try temporaryFixture("SyncedApp", project: "SyncedApp.xcodeproj")
        let pbxproj = projectURL.appendingPathComponent("project.pbxproj")
        let original = try String(contentsOf: pbxproj, encoding: .utf8)

        let project = try ProjectorProject.load(at: projectURL)
        let outcome = try project.save()

        #expect(outcome.fidelity == .none)
        #expect(!outcome.wroteFile)
        let after = try String(contentsOf: pbxproj, encoding: .utf8)
        #expect(after == original)
    }

    @Test func checkOnUntouchedProjectReportsNoChanges() throws {
        let projectURL = try temporaryFixture("SyncedApp", project: "SyncedApp.xcodeproj")
        let project = try ProjectorProject.load(at: projectURL)
        let check = try project.check()
        #expect(!check.hasChanges)
        #expect(check.diff.isEmpty)
    }

    // MARK: - Modifying one object block

    @Test func changingOneBuildSettingProducesTinySurgicalDiff() throws {
        let projectURL = try temporaryFixture("SyncedApp", project: "SyncedApp.xcodeproj")
        let project = try ProjectorProject.load(at: projectURL)

        // Flip SWIFT_VERSION on the target's Debug configuration.
        let target = try project.nativeTarget(named: "SyncedApp")
        let debug = try #require(target.buildConfigurationList?.buildConfigurations.first { $0.name == "Debug" })
        debug.buildSettings["SWIFT_VERSION"] = .string("6.0")

        let check = try project.check()
        #expect(check.fidelity == .surgical)
        // Only the single setting line changes.
        #expect(check.diff.added == 1)
        #expect(check.diff.removed == 1)
        #expect(check.diff.unified().contains("SWIFT_VERSION = 6.0"))

        let outcome = try project.save()
        #expect(outcome.wroteFile)
        #expect(outcome.fidelity == .surgical)

        // The written file reparses and the change stuck.
        let reloaded = try ProjectorProject.load(at: projectURL)
        let value = try BuildSettingResolver(project: reloaded)
            .resolve(key: "SWIFT_VERSION", target: "SyncedApp")
            .first { $0.configuration == "Debug" }
        #expect(value?.value == "6.0")
    }

    // MARK: - Adding objects, incl. a brand-new section

    @Test func addingBuildFileCreatesNewSectionSurgically() throws {
        let projectURL = try temporaryFixture("SyncedApp", project: "SyncedApp.xcodeproj")
        let project = try ProjectorProject.load(at: projectURL)

        // Create a real source file on disk so validation doesn't warn.
        let sourceRoot = projectURL.deletingLastPathComponent()
        try "import Foundation\n".write(
            to: sourceRoot.appendingPathComponent("Extra.swift"), atomically: true, encoding: .utf8)

        // Add a file reference into the main group and a build file into Sources.
        // (The fixture has no PBXBuildFile section, so this exercises new-section
        // insertion.)
        let fileRef = PBXFileReference(sourceTree: .group, name: nil, path: "Extra.swift")
        project.pbxproj.add(object: fileRef)
        let root = try project.rootProject
        root.mainGroup.children.append(fileRef)

        let target = try project.nativeTarget(named: "SyncedApp")
        let sources = try #require(target.buildPhases.first { $0.buildPhase == .sources })
        let buildFile = PBXBuildFile(file: fileRef)
        project.pbxproj.add(object: buildFile)
        sources.files?.append(buildFile)

        let check = try project.check()
        #expect(check.fidelity == .surgical)
        #expect(check.diff.unified().contains("Begin PBXBuildFile section"))

        let outcome = try project.save()
        #expect(outcome.fidelity == .surgical)
        #expect(outcome.wroteFile)

        // Reparse and confirm the build file is wired into Sources.
        let reloaded = try ProjectorProject.load(at: projectURL)
        let phase = try reloaded.nativeTarget(named: "SyncedApp").buildPhases
            .first { $0.buildPhase == .sources }
        #expect(phase?.files?.contains { $0.file?.path == "Extra.swift" } == true)
    }

    // MARK: - Surgical value on a style-divergent project

    /// A project whose on-disk text is NOT in XcodeProj's canonical style. A
    /// full reserialize would rewrite many lines; the surgical writer must keep
    /// untouched blocks byte-for-byte and confine the diff to the changed block.
    @Test func styleDivergentProjectKeepsUntouchedBytes() throws {
        let quirky = Self.quirkyProject
        let index = try PBXTextIndex(text: quirky)  // must index despite quirks

        // Sanity: a full reserialize really does differ from the quirky text,
        // so this test is meaningful.
        let reserialized = try SerializationStyle.serialize(PBXProj(data: Data(quirky.utf8)))
        #expect(reserialized != quirky)

        // Mutate one build setting via the graph, then splice.
        let proj = try PBXProj(data: Data(quirky.utf8))
        let config = try #require(proj.buildConfigurations.first { $0.name == "Debug" })
        config.buildSettings["PRODUCT_NAME"] = .string("Renamed")

        let result = try SurgicalWriter.produce(pristineText: quirky, mutatedProj: proj)
        #expect(result.fidelity == .surgical)

        // The untouched Release block — including its hand-written comment that
        // XcodeProj would strip on a full reserialize — survives verbatim, while
        // the Debug block reflects the change. Proof that unchanged bytes are
        // preserved and only the changed block is restyled.
        #expect(result.text.contains("// a hand-written note Xcode would never emit"))
        #expect(result.text.contains("PRODUCT_NAME = Renamed;"))
        #expect(result.text.contains("PRODUCT_NAME = ReleaseName;"))
        _ = index
    }

    /// Minimal but valid pbxproj with a real PBXProject root and deliberately
    /// non-canonical styling (a hand-written comment) that XcodeProj normalizes
    /// away on a full reserialize.
    static let quirkyProject = """
    // !$*UTF8*$!
    {
    \tarchiveVersion = 1;
    \tclasses = {
    \t};
    \tobjectVersion = 56;
    \tobjects = {

    /* Begin PBXGroup section */
    \t\tGRP00000000000000000001 = {
    \t\t\tisa = PBXGroup;
    \t\t\tchildren = (
    \t\t\t);
    \t\t\tsourceTree = "<group>";
    \t\t};
    /* End PBXGroup section */

    /* Begin PBXProject section */
    \t\tPRJ00000000000000000001 /* Project object */ = {
    \t\t\tisa = PBXProject;
    \t\t\tbuildConfigurationList = LIST0000000000000000001 /* Build configuration list for PBXProject "Quirky" */;
    \t\t\tcompatibilityVersion = "Xcode 14.0";
    \t\t\tdevelopmentRegion = en;
    \t\t\thasScannedForEncodings = 0;
    \t\t\tknownRegions = (
    \t\t\t\ten,
    \t\t\t);
    \t\t\tmainGroup = GRP00000000000000000001;
    \t\t\tprojectDirPath = "";
    \t\t\tprojectRoot = "";
    \t\t\ttargets = (
    \t\t\t);
    \t\t};
    /* End PBXProject section */

    /* Begin XCBuildConfiguration section */
    \t\tCFG00000000000000000001 /* Debug */ = {
    \t\t\tisa = XCBuildConfiguration;
    \t\t\tbuildSettings = {
    \t\t\t\tPRODUCT_NAME = DebugName;
    \t\t\t};
    \t\t\tname = Debug;
    \t\t};
    \t\tCFG00000000000000000002 /* Release */ = {
    \t\t\tisa = XCBuildConfiguration;
    \t\t\tbuildSettings = {
    \t\t\t\t// a hand-written note Xcode would never emit
    \t\t\t\tPRODUCT_NAME = ReleaseName;
    \t\t\t};
    \t\t\tname = Release;
    \t\t};
    /* End XCBuildConfiguration section */

    /* Begin XCConfigurationList section */
    \t\tLIST0000000000000000001 /* Build configuration list for PBXProject "Quirky" */ = {
    \t\t\tisa = XCConfigurationList;
    \t\t\tbuildConfigurations = (
    \t\t\t\tCFG00000000000000000001 /* Debug */,
    \t\t\t\tCFG00000000000000000002 /* Release */,
    \t\t\t);
    \t\t\tdefaultConfigurationIsVisible = 0;
    \t\t};
    /* End XCConfigurationList section */
    \t};
    \trootObject = PRJ00000000000000000001 /* Project object */;
    }

    """
}
