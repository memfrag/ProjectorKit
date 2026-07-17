import Foundation
import PathKit
import XcodeProj

/// Declarative description of a shared scheme to create.
public struct SchemeSpec: Sendable {
    public var name: String
    /// The target the scheme builds and (if applicable) launches.
    public var targetName: String
    /// Unit/UI test target names to include in the Test action.
    public var testTargetNames: [String]

    public init(name: String, targetName: String, testTargetNames: [String] = []) {
        self.name = name
        self.targetName = targetName
        self.testTargetNames = testTargetNames
    }
}

public extension ProjectorProject {
    /// A pending write to a `.xcscheme` file: computed but not yet applied, so
    /// callers can preview it (mirrors `XCConfigEditor.Plan`).
    struct SchemeWritePlan {
        public let path: URL
        let scheme: XCScheme
        public let originalText: String
        public let newText: String
        public var diff: DiffReport { DiffReport(old: originalText, new: newText) }
        public var hasChanges: Bool { originalText != newText }
    }

    /// Computes the scheme XML a `addScheme` call would write, without writing
    /// it. Returns `hasChanges == false` when a shared scheme with this name
    /// already exists (schemes are treated as create-only; re-running with the
    /// same name is idempotent).
    func planScheme(_ spec: SchemeSpec) throws -> SchemeWritePlan {
        let path = xcshareddataSchemesDirectory.appendingPathComponent("\(spec.name).xcscheme")

        if (xcodeProj.sharedData?.schemes.contains { $0.name == spec.name }) == true {
            let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
            let scheme = try XCScheme(pathString: path.path)
            return SchemeWritePlan(path: path, scheme: scheme, originalText: existing, newText: existing)
        }

        let scheme = try buildScheme(spec)
        guard let data = try scheme.dataRepresentation(), let newText = String(data: data, encoding: .utf8) else {
            throw ProjectorError.writeFailure(path: path.path, reason: "scheme serialization produced no data")
        }
        let original = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        return SchemeWritePlan(path: path, scheme: scheme, originalText: original, newText: newText)
    }

    /// Writes a previously computed plan atomically, with an optional sibling
    /// backup, and registers it in the in-memory shared-data model.
    func applyScheme(_ plan: SchemeWritePlan, backup: Bool = true) throws {
        guard plan.hasChanges else { return }
        try FileManager.default.createDirectory(
            at: plan.path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicWriter.write(plan.newText, to: plan.path, backup: backup)

        if xcodeProj.sharedData == nil {
            xcodeProj.sharedData = XCSharedData(schemes: [])
        }
        xcodeProj.sharedData?.schemes.removeAll { $0.name == plan.scheme.name }
        xcodeProj.sharedData?.schemes.append(plan.scheme)
    }

    /// Convenience: plans and immediately applies. Idempotent (a name that
    /// already exists as a shared scheme returns `.alreadySatisfied`).
    @discardableResult
    func addScheme(_ spec: SchemeSpec, backup: Bool = true) throws -> OperationResult {
        let plan = try planScheme(spec)
        guard plan.hasChanges else { return .alreadySatisfied }
        try applyScheme(plan, backup: backup)
        return .applied(changes: [
            ChangeDescription(kind: "scheme", detail: "create scheme \(spec.name)", target: spec.targetName),
        ])
    }

    private var xcshareddataSchemesDirectory: URL {
        xcodeprojPath.appendingPathComponent("xcshareddata/xcschemes")
    }

    private func buildScheme(_ spec: SchemeSpec) throws -> XCScheme {
        let primary = try target(named: spec.targetName)
        let container = "container:\(xcodeprojPath.lastPathComponent)"

        func reference(for target: PBXTarget) -> XCScheme.BuildableReference {
            XCScheme.BuildableReference(
                referencedContainer: container, blueprint: target,
                buildableName: productNameWithExtension(target) ?? target.name,
                blueprintName: target.name)
        }

        let primaryRef = reference(for: primary)
        let testTargets = try spec.testTargetNames.map { try target(named: $0) }

        var buildEntries = [XCScheme.BuildAction.Entry(buildableReference: primaryRef, buildFor: XCScheme.BuildAction.Entry.BuildFor.default)]
        buildEntries += testTargets.map {
            XCScheme.BuildAction.Entry(buildableReference: reference(for: $0), buildFor: XCScheme.BuildAction.Entry.BuildFor.testOnly)
        }
        let buildAction = XCScheme.BuildAction(buildActionEntries: buildEntries, parallelizeBuild: true, buildImplicitDependencies: true)

        let testAction = XCScheme.TestAction(
            buildConfiguration: "Debug", macroExpansion: testTargets.isEmpty ? primaryRef : nil,
            testables: testTargets.map { XCScheme.TestableReference(skipped: false, buildableReference: reference(for: $0)) })

        let isRunnable: Bool
        if let native = primary as? PBXNativeTarget {
            isRunnable = [.application, .commandLineTool, .xpcService, .appExtension].contains(native.productType)
        } else {
            isRunnable = false
        }

        let launchAction = XCScheme.LaunchAction(
            runnable: isRunnable ? XCScheme.BuildableProductRunnable(buildableReference: primaryRef) : nil,
            buildConfiguration: "Debug",
            macroExpansion: isRunnable ? nil : primaryRef)

        let profileAction = XCScheme.ProfileAction(
            runnable: isRunnable ? XCScheme.BuildableProductRunnable(buildableReference: primaryRef) : nil,
            buildConfiguration: "Release",
            macroExpansion: isRunnable ? nil : primaryRef)

        let archiveAction = XCScheme.ArchiveAction(buildConfiguration: "Release", revealArchiveInOrganizer: true)

        return XCScheme(
            name: spec.name, lastUpgradeVersion: schemeLastUpgradeVersion(), version: "1.7",
            buildAction: buildAction, testAction: testAction, launchAction: launchAction,
            profileAction: profileAction, analyzeAction: XCScheme.AnalyzeAction(buildConfiguration: "Debug"),
            archiveAction: archiveAction)
    }

    private func productNameWithExtension(_ target: PBXTarget) -> String? {
        (target as? PBXNativeTarget)?.product?.path
    }

    private func schemeLastUpgradeVersion() -> String {
        ((try? rootProject.attributes["LastUpgradeCheck"]) ?? nil)?.stringValue ?? "1600"
    }
}
