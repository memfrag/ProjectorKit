import Foundation
import XcodeProj

/// Facade over a loaded `.xcodeproj`: load → inspect/mutate → check/save.
///
/// Not thread-safe and not `Sendable` by design (XcodeProj's object graph is
/// mutable reference types). Use one instance per project per operation
/// sequence, on a single thread.
public final class ProjectorProject {
    /// Path to the `.xcodeproj` directory.
    public let xcodeprojPath: URL
    /// Path to `project.pbxproj` inside it.
    public let pbxprojPath: URL

    /// The underlying XcodeProj document (workspace, schemes, pbxproj).
    /// Exposed as an escape hatch; mutations made directly here bypass
    /// Projector's intent API but still flow through the same save pipeline.
    public let xcodeProj: XcodeProj

    /// The pbxproj text exactly as read from disk at load time.
    let pristineText: String
    /// mtime+size of the pbxproj at load time, for optimistic locking.
    let loadedFingerprint: FileFingerprint

    /// Non-fatal notes accumulated during operations, surfaced to CLI output.
    public private(set) var warnings: [String] = []

    /// objectVersions we know how to preserve safely. Anything newer is
    /// refused rather than guessed at.
    static let maximumKnownObjectVersion: UInt = 77

    public static func load(at path: URL) throws -> ProjectorProject {
        try ProjectorProject(xcodeprojPath: path)
    }

    private init(xcodeprojPath: URL) throws {
        let standardized = xcodeprojPath.standardizedFileURL
        let pbxprojURL = standardized.appendingPathComponent("project.pbxproj")

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.fileExists(atPath: pbxprojURL.path)
        else {
            throw ProjectorError.projectNotFound(path: standardized.path)
        }

        self.xcodeprojPath = standardized
        self.pbxprojPath = pbxprojURL

        do {
            self.pristineText = try String(contentsOf: pbxprojURL, encoding: .utf8)
        } catch {
            throw ProjectorError.parseFailure(path: pbxprojURL.path, underlying: "not readable as UTF-8: \(error)")
        }

        self.loadedFingerprint = try FileFingerprint(of: pbxprojURL)

        do {
            self.xcodeProj = try XcodeProj(pathString: standardized.path)
        } catch {
            throw ProjectorError.parseFailure(path: pbxprojURL.path, underlying: String(describing: error))
        }

        let objectVersion = xcodeProj.pbxproj.objectVersion
        guard objectVersion <= Self.maximumKnownObjectVersion else {
            throw ProjectorError.unsupportedObjectVersion(Int(objectVersion))
        }
    }

    // MARK: - Accessors

    public var pbxproj: PBXProj { xcodeProj.pbxproj }

    public var rootProject: PBXProject {
        get throws {
            guard let root = try? pbxproj.rootProject() else {
                throw ProjectorError.parseFailure(path: pbxprojPath.path, underlying: "missing rootObject")
            }
            return root
        }
    }

    /// All targets: native, aggregate, and legacy.
    public var targets: [PBXTarget] {
        pbxproj.nativeTargets.map { $0 as PBXTarget }
            + pbxproj.aggregateTargets.map { $0 as PBXTarget }
            + pbxproj.legacyTargets.map { $0 as PBXTarget }
    }

    public func target(named name: String) throws -> PBXTarget {
        guard let target = targets.first(where: { $0.name == name }) else {
            let available = targets.map(\.name).sorted().joined(separator: ", ")
            throw ProjectorError.notFound(kind: "Target", name: name, hint: "Available targets: \(available)")
        }
        return target
    }

    public func nativeTarget(named name: String) throws -> PBXNativeTarget {
        let target = try target(named: name)
        guard let native = target as? PBXNativeTarget else {
            throw ProjectorError.invalidOperation("Target '\(name)' is not a native target")
        }
        return native
    }

    func note(_ warning: String) {
        warnings.append(warning)
    }
}

/// Cheap identity of a file's on-disk state, for optimistic locking.
struct FileFingerprint: Equatable {
    let modificationDate: Date
    let size: Int

    init(of url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let mtime = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? Int
        else {
            throw ProjectorError.writeFailure(path: url.path, reason: "could not stat file")
        }
        self.modificationDate = mtime
        self.size = size
    }
}
