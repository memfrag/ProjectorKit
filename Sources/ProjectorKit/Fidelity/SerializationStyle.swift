import Foundation
import XcodeProj

/// The single, pinned serialization configuration used everywhere Projector
/// serializes a pbxproj graph. Centralized so output bytes never vary between
/// call sites, and so a deliberate style change is a one-line, golden-re-baselined
/// commit.
enum SerializationStyle {
    /// - `projFileListOrder: .byUUID` matches Xcode's ordering of the objects
    ///   sections.
    /// - `.unsorted` navigator/build-phase order preserves the input file's
    ///   ordering rather than re-sorting the user's project.
    /// - `.xcode` reference format emits 24-hex-char identifiers
    ///   indistinguishable from Xcode-generated ones.
    static var pinned: PBXOutputSettings {
        PBXOutputSettings(
            projFileListOrder: .byUUID,
            projNavigatorFileOrder: .unsorted,
            projBuildPhaseFileOrder: .unsorted,
            projReferenceFormat: .xcode
        )
    }

    /// Serializes a graph with the pinned settings. Note: this resolves any
    /// temporary references on new objects (deterministically) as a side effect.
    static func serialize(_ proj: PBXProj) throws -> String {
        guard let data = try proj.dataRepresentation(outputSettings: pinned),
              let text = String(data: data, encoding: .utf8)
        else {
            throw ProjectorError.writeFailure(path: "<in-memory>", reason: "pbxproj serialization produced no data")
        }
        return text
    }
}
