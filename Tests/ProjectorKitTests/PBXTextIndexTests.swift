import Foundation
import Testing
@testable import ProjectorKit

@Suite struct PBXTextIndexTests {
    /// Every fixture must index completely, and every entry's substring must be
    /// a slice of the original — the whole file must round-trip.
    @Test func indexesFixtureAndRoundTrips() throws {
        let url = try fixtureURL("SyncedApp")
            .appendingPathComponent("SyncedApp.xcodeproj/project.pbxproj")
        let text = try String(contentsOf: url, encoding: .utf8)
        let index = try PBXTextIndex(text: text)

        #expect(index.text() == text)
        // Known entries from the fixture are present with correct ISA.
        let root = try #require(index.entries["A10000010000000000000009"])
        #expect(root.isa == "PBXProject")
        let syncedGroup = try #require(index.entries["A10000010000000000000004"])
        #expect(syncedGroup.isa == "PBXFileSystemSynchronizedRootGroup")

        // Each entry's slice appears verbatim in the source.
        for (_, entry) in index.entries {
            #expect(text.contains(index.substring(entry.range)))
        }
        // Sections are recorded in file order.
        #expect(index.sectionOrder.first == "PBXFileReference")
        #expect(index.sectionOrder.contains("XCConfigurationList"))
    }

    @Test func singleLineEntryIsIndexed() throws {
        let text = """
        // !$*UTF8*$!
        {
        \tobjects = {

        /* Begin PBXFileReference section */
        \t\tABC123 /* App.app */ = {isa = PBXFileReference; path = App.app; sourceTree = BUILT_PRODUCTS_DIR; };
        /* End PBXFileReference section */
        \t};
        \trootObject = ABC123;
        }
        """
        let index = try PBXTextIndex(text: text)
        let entry = try #require(index.entries["ABC123"])
        #expect(entry.isa == "PBXFileReference")
        #expect(index.substring(entry.range).contains("App.app"))
    }

    /// The adversarial case: a shell script value containing braces, comment
    /// markers, quotes, and semicolons must not confuse entry boundaries.
    @Test func shellScriptWithBracesAndCommentsDoesNotBreakScanning() throws {
        let text = """
        // !$*UTF8*$!
        {
        \tobjects = {

        /* Begin PBXShellScriptBuildPhase section */
        \t\tSCRIPT1 /* Run Script */ = {
        \t\t\tisa = PBXShellScriptBuildPhase;
        \t\t\tshellScript = "if [ true ]; then echo \\"a { b } /* not a comment */ ;\\"; fi\\n";
        \t\t};
        /* End PBXShellScriptBuildPhase section */

        /* Begin PBXFileReference section */
        \t\tFILE1 /* B.swift */ = {isa = PBXFileReference; path = B.swift; sourceTree = "<group>"; };
        /* End PBXFileReference section */
        \t};
        \trootObject = SCRIPT1;
        }
        """
        let index = try PBXTextIndex(text: text)
        #expect(index.entries.count == 2)
        let script = try #require(index.entries["SCRIPT1"])
        #expect(script.isa == "PBXShellScriptBuildPhase")
        #expect(index.substring(script.range).contains("not a comment"))
        // The file reference after the script was still found correctly.
        let file = try #require(index.entries["FILE1"])
        #expect(file.isa == "PBXFileReference")
        #expect(index.text() == text)
    }

    @Test func quotedReferenceKeyIsHandled() throws {
        let text = """
        // !$*UTF8*$!
        {
        \tobjects = {

        /* Begin PBXGroup section */
        \t\t"weird key" /* Group */ = {
        \t\t\tisa = PBXGroup;
        \t\t\tchildren = (
        \t\t\t);
        \t\t\tsourceTree = "<group>";
        \t\t};
        /* End PBXGroup section */
        \t};
        \trootObject = "weird key";
        }
        """
        let index = try PBXTextIndex(text: text)
        let entry = try #require(index.entries["\"weird key\""])
        #expect(entry.isa == "PBXGroup")
    }

    @Test func missingObjectsBlockThrows() {
        #expect(throws: PBXTextIndex.IndexError.self) {
            try PBXTextIndex(text: "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n}\n")
        }
    }
}
