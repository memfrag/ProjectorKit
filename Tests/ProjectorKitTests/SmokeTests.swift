import Foundation
import Testing
@testable import ProjectorKit

/// Locates a committed fixture project inside the test bundle.
func fixtureURL(_ name: String) throws -> URL {
    let root = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    let url = root.appendingPathComponent(name)
    try #require(FileManager.default.fileExists(atPath: url.path), "missing fixture \(name)")
    return url
}

/// Copies a fixture to a temp directory so mutation tests never touch the
/// committed copy. Returns the .xcodeproj URL inside the copy.
func temporaryFixture(_ name: String, project: String) throws -> URL {
    let source = try fixtureURL(name)
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("projector-tests-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: source, to: scratch)
    return scratch.appendingPathComponent(project)
}

@Suite struct SmokeTests {
    @Test func loadsSyncedAppFixture() throws {
        let project = try ProjectorProject.load(
            at: fixtureURL("SyncedApp").appendingPathComponent("SyncedApp.xcodeproj"))
        #expect(project.targets.map(\.name) == ["SyncedApp"])
        #expect(project.pbxproj.objectVersion == 77)
    }

    @Test func missingProjectThrows() {
        #expect(throws: ProjectorError.self) {
            try ProjectorProject.load(at: URL(fileURLWithPath: "/nonexistent/Nope.xcodeproj"))
        }
    }
}
