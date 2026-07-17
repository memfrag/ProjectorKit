import Foundation
import XcodeProj

/// Maps a file extension to the build phase it belongs in.
enum BuildPhaseMapping {
    enum Phase {
        case sources
        case resources
        case frameworks
        case headers
        /// Not built (e.g. entitlements, Info.plist, xcconfig, README).
        case none
    }

    static let sourceExtensions: Set<String> = [
        "swift", "m", "mm", "c", "cc", "cpp", "cxx", "s", "metal",
        "intentdefinition", "mlmodel", "rcproject",
    ]
    static let frameworkExtensions: Set<String> = [
        "framework", "xcframework", "a", "dylib", "tbd",
    ]
    static let headerExtensions: Set<String> = ["h", "hpp", "hh", "hxx", "pch"]
    /// Files that live in the project but are never in a build phase.
    static let unbuiltExtensions: Set<String> = [
        "entitlements", "xcconfig", "modulemap", "md", "txt", "gitignore",
    ]

    static func phase(forExtension ext: String, isFrameworkTarget: Bool) -> Phase {
        let lower = ext.lowercased()
        if sourceExtensions.contains(lower) { return .sources }
        if frameworkExtensions.contains(lower) { return .frameworks }
        if headerExtensions.contains(lower) { return isFrameworkTarget ? .headers : .none }
        if unbuiltExtensions.contains(lower) { return .none }
        // Info.plist is referenced via build settings, not a resource.
        if lower == "plist" { return .resources }
        // Default: treat unknown extensions as resources (assets, storyboards,
        // json, strings, images, etc.).
        return .resources
    }
}
