import Foundation

/// Versioned, Codable read model of a project. This is the machine contract
/// behind all `--json` inspect output: additive changes only within a
/// `schemaVersion`.
public struct ProjectSnapshot: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int = ProjectSnapshot.currentSchemaVersion
    public let name: String
    public let path: String
    public let objectVersion: Int
    public let configurations: [String]
    public let targets: [TargetSnapshot]
    public let files: [FileSnapshot]
    public let packages: [PackageSnapshot]
    /// Shared scheme names (from xcshareddata). Xcode also auto-generates
    /// per-target schemes that have no file on disk; those are not listed.
    public let sharedSchemes: [String]
}

public struct TargetSnapshot: Codable, Sendable {
    public let name: String
    /// e.g. "com.apple.product-type.application"; "aggregate" / "legacy" for
    /// non-native targets.
    public let productType: String
    public let productName: String?
    /// PRODUCT_BUNDLE_IDENTIFIER from the target's build settings, if set
    /// uniformly across configurations.
    public let bundleIdentifier: String?
    /// Names of targets this target depends on.
    public let dependencies: [String]
    /// Swift package products linked into this target.
    public let packageProducts: [String]
    public let buildPhases: [BuildPhaseSnapshot]
    /// Paths of synchronized root folders (Xcode 16+) attached to this target.
    public let synchronizedRoots: [String]
}

public struct BuildPhaseSnapshot: Codable, Sendable {
    /// "sources", "resources", "frameworks", "headers", "copyFiles",
    /// "runScript", "carbonResources"
    public let kind: String
    /// Custom name (copy-files and run-script phases).
    public let name: String?
    /// Project-relative paths of files in this phase (classic build files
    /// only; synchronized-folder members are implicit and not listed here).
    public let files: [String]
}

public struct FileSnapshot: Codable, Sendable {
    /// Project-directory-relative path.
    public let path: String
    /// Names of targets this file is built into.
    public let targets: [String]
    /// True when membership comes from a synchronized root folder rather than
    /// explicit PBXBuildFile entries.
    public let synchronized: Bool
}

public struct PackageSnapshot: Codable, Sendable {
    /// "remote" or "local"
    public let kind: String
    /// Repository URL (remote) or relative path (local).
    public let location: String
    /// Version requirement description (remote only), e.g. "upToNextMajor(1.2.0)".
    public let requirement: String?
    /// Product names linked, with the targets linking them.
    public let products: [PackageProductSnapshot]
}

public struct PackageProductSnapshot: Codable, Sendable {
    public let name: String
    public let targets: [String]
}
