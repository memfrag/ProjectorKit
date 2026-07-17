import Foundation
import PathKit
import XcodeProj

/// A version requirement for a remote Swift package.
public enum PackageRequirement: Sendable {
    case upToNextMajor(String)
    case upToNextMinor(String)
    case exact(String)
    case range(from: String, to: String)
    case branch(String)
    case revision(String)

    var xcodeProjValue: XCRemoteSwiftPackageReference.VersionRequirement {
        switch self {
        case .upToNextMajor(let v): .upToNextMajorVersion(v)
        case .upToNextMinor(let v): .upToNextMinorVersion(v)
        case .exact(let v): .exact(v)
        case .range(let from, let to): .range(from: from, to: to)
        case .branch(let b): .branch(b)
        case .revision(let r): .revision(r)
        }
    }
}

public extension ProjectorProject {
    /// Adds (or reuses) a remote Swift package reference and links `product`
    /// into `targetName`'s Frameworks phase. Idempotent: reuses an existing
    /// reference for the same URL, and does not duplicate the product link.
    @discardableResult
    func addRemotePackage(
        url: String, requirement: PackageRequirement, product: String, target targetName: String
    ) throws -> OperationResult {
        let nativeTarget = try nativeTarget(named: targetName)
        var changes: [ChangeDescription] = []

        let root = try rootProject
        let reference: XCRemoteSwiftPackageReference
        if let existing = root.remotePackages.first(where: { $0.repositoryURL == url }) {
            reference = existing
        } else {
            reference = XCRemoteSwiftPackageReference(repositoryURL: url, versionRequirement: requirement.xcodeProjValue)
            pbxproj.add(object: reference)
            root.remotePackages.append(reference)
            changes.append(ChangeDescription(kind: "packageReference", detail: "add package \(url)"))
        }

        if try linkProduct(product, package: reference, into: nativeTarget, changes: &changes) {
            return .applied(changes: changes)
        }
        return changes.isEmpty ? .alreadySatisfied : .applied(changes: changes)
    }

    /// Adds (or reuses) a local Swift package reference and links `product`
    /// into `targetName`'s Frameworks phase. Idempotent.
    @discardableResult
    func addLocalPackage(
        path: String, product: String, target targetName: String
    ) throws -> OperationResult {
        let nativeTarget = try nativeTarget(named: targetName)
        var changes: [ChangeDescription] = []
        let root = try rootProject

        if root.localPackages.first(where: { $0.relativePath == path }) == nil {
            let reference = XCLocalSwiftPackageReference(relativePath: path)
            pbxproj.add(object: reference)
            root.localPackages.append(reference)
            changes.append(ChangeDescription(kind: "packageReference", detail: "add local package \(path)"))
        }

        // Local package products have no `package` back-reference in XcodeProj's
        // model (only remote ones do); dedupe by product name already linked to
        // this target instead.
        let alreadyLinked = (nativeTarget.packageProductDependencies ?? []).contains { $0.productName == product }
        if alreadyLinked {
            return changes.isEmpty ? .alreadySatisfied : .applied(changes: changes)
        }

        let dependency = XCSwiftPackageProductDependency(productName: product)
        pbxproj.add(object: dependency)
        nativeTarget.packageProductDependencies = (nativeTarget.packageProductDependencies ?? []) + [dependency]

        let buildFile = PBXBuildFile(product: dependency)
        pbxproj.add(object: buildFile)
        guard let frameworks = try nativeTarget.frameworksBuildPhase() else {
            throw ProjectorError.invalidOperation("Target '\(targetName)' has no Frameworks build phase")
        }
        frameworks.files?.append(buildFile)
        changes.append(ChangeDescription(kind: "packageProduct", detail: "link \(product)", target: targetName))

        return .applied(changes: changes)
    }

    /// Removes a remote or local package reference by URL/path, and unlinks any
    /// products it provided from all targets. Idempotent.
    @discardableResult
    func removePackage(urlOrPath: String) throws -> OperationResult {
        let root = try rootProject
        var changes: [ChangeDescription] = []

        if let remote = root.remotePackages.first(where: { $0.repositoryURL == urlOrPath }) {
            var productDeps: [XCSwiftPackageProductDependency] = []
            for candidate in pbxproj.nativeTargets.flatMap({ $0.packageProductDependencies ?? [] })
                where candidate.package === remote {
                if !productDeps.contains(where: { $0 === candidate }) {
                    productDeps.append(candidate)
                }
            }
            unlinkProducts(productDeps, changes: &changes)
            root.remotePackages.removeAll { $0 === remote }
            pbxproj.delete(object: remote)
            changes.append(ChangeDescription(kind: "packageReference", detail: "remove package \(urlOrPath)"))
        }
        if let local = root.localPackages.first(where: { $0.relativePath == urlOrPath }) {
            root.localPackages.removeAll { $0 === local }
            pbxproj.delete(object: local)
            changes.append(ChangeDescription(kind: "packageReference", detail: "remove local package \(urlOrPath)"))
        }

        return changes.isEmpty ? .alreadySatisfied : .applied(changes: changes)
    }

    // MARK: - Helpers

    /// Links a remote package's product into a target if not already linked.
    /// Returns true if a change was made.
    private func linkProduct(
        _ product: String, package: XCRemoteSwiftPackageReference,
        into target: PBXNativeTarget, changes: inout [ChangeDescription]
    ) throws -> Bool {
        let alreadyLinked = (target.packageProductDependencies ?? [])
            .contains { $0.productName == product && $0.package === package }
        if alreadyLinked { return false }

        let dependency = XCSwiftPackageProductDependency(productName: product, package: package)
        pbxproj.add(object: dependency)
        target.packageProductDependencies = (target.packageProductDependencies ?? []) + [dependency]

        let buildFile = PBXBuildFile(product: dependency)
        pbxproj.add(object: buildFile)
        guard let frameworks = try target.frameworksBuildPhase() else {
            throw ProjectorError.invalidOperation("Target '\(target.name)' has no Frameworks build phase")
        }
        frameworks.files?.append(buildFile)
        changes.append(ChangeDescription(kind: "packageProduct", detail: "link \(product)", target: target.name))
        return true
    }

    private func unlinkProducts(_ products: [XCSwiftPackageProductDependency], changes: inout [ChangeDescription]) {
        for product in products {
            for nativeTarget in pbxproj.nativeTargets {
                nativeTarget.packageProductDependencies?.removeAll { $0 === product }
            }
            for phase in pbxproj.buildPhases {
                for buildFile in (phase.files ?? []) where buildFile.product === product {
                    phase.files?.removeAll { $0 === buildFile }
                    pbxproj.delete(object: buildFile)
                }
            }
            pbxproj.delete(object: product)
            changes.append(ChangeDescription(kind: "packageProduct", detail: "unlink \(product.productName)"))
        }
    }
}
