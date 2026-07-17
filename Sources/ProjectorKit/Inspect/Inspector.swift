import Foundation
import XcodeProj

/// Builds the Codable read model (`ProjectSnapshot`) from a loaded project.
public struct Inspector {
    let project: ProjectorProject

    /// Directory-like file types Xcode treats as a single unit; their contents
    /// are not enumerated when listing synchronized folders.
    static let bundleLikeExtensions: Set<String> = [
        "xcassets", "xcdatamodeld", "scnassets", "docc", "bundle",
        "framework", "xcframework", "lproj", "playground", "rcproject",
    ]

    public init(project: ProjectorProject) {
        self.project = project
    }

    /// The directory that `<group>`-relative paths resolve against.
    var sourceRoot: URL {
        project.xcodeprojPath.deletingLastPathComponent()
    }

    public func snapshot() throws -> ProjectSnapshot {
        let root = try project.rootProject
        return ProjectSnapshot(
            name: project.xcodeprojPath.deletingPathExtension().lastPathComponent,
            path: project.xcodeprojPath.path,
            objectVersion: Int(project.pbxproj.objectVersion),
            configurations: root.buildConfigurationList.buildConfigurations.map(\.name),
            targets: try project.targets.map(targetSnapshot),
            files: try fileSnapshots(),
            packages: try packageSnapshots(root: root),
            sharedSchemes: project.xcodeProj.sharedData?.schemes.map(\.name).sorted() ?? []
        )
    }

    // MARK: - Targets

    public func targetSnapshot(_ target: PBXTarget) throws -> TargetSnapshot {
        let productType: String
        switch target {
        case let native as PBXNativeTarget:
            productType = native.productType?.rawValue ?? "unknown"
        case is PBXAggregateTarget:
            productType = "aggregate"
        default:
            productType = "legacy"
        }

        let dependencies = target.dependencies.compactMap { $0.target?.name ?? $0.name }

        let packageProducts = (target as? PBXNativeTarget)?
            .packageProductDependencies?
            .compactMap(\.productName) ?? []

        let synchronizedRoots = (target.fileSystemSynchronizedGroups ?? [])
            .compactMap(\.path)

        return TargetSnapshot(
            name: target.name,
            productType: productType,
            productName: target.productName,
            bundleIdentifier: uniformSetting("PRODUCT_BUNDLE_IDENTIFIER", of: target),
            dependencies: dependencies,
            packageProducts: packageProducts,
            buildPhases: try target.buildPhases.map(phaseSnapshot),
            synchronizedRoots: synchronizedRoots
        )
    }

    /// Returns a setting's value when it is identical across all of the
    /// target's configurations, else nil.
    func uniformSetting(_ key: String, of target: PBXTarget) -> String? {
        guard let configurations = target.buildConfigurationList?.buildConfigurations,
              !configurations.isEmpty
        else { return nil }
        let values = Set(configurations.map { $0.buildSettings[key]?.description ?? "" })
        return values.count == 1 ? values.first.flatMap { $0.isEmpty ? nil : $0 } : nil
    }

    func phaseSnapshot(_ phase: PBXBuildPhase) throws -> BuildPhaseSnapshot {
        let kind: String = switch phase.buildPhase {
        case .sources: "sources"
        case .frameworks: "frameworks"
        case .resources: "resources"
        case .copyFiles: "copyFiles"
        case .runScript: "runScript"
        case .headers: "headers"
        case .carbonResources: "carbonResources"
        }
        let files = (phase.files ?? []).compactMap { buildFile -> String? in
            if let element = buildFile.file {
                return (try? relativePath(of: element)) ?? element.path
            }
            if let product = buildFile.product {
                return product.productName
            }
            return nil
        }
        return BuildPhaseSnapshot(kind: kind, name: phase.name(), files: files)
    }

    // MARK: - Files

    func relativePath(of element: PBXFileElement) throws -> String? {
        guard let full = try element.fullPath(sourceRoot: sourceRoot.path) else { return nil }
        let rootPath = sourceRoot.standardizedFileURL.path
        if full.hasPrefix(rootPath + "/") {
            return String(full.dropFirst(rootPath.count + 1))
        }
        return full
    }

    public func fileSnapshots() throws -> [FileSnapshot] {
        var snapshots: [FileSnapshot] = []

        // Classic file references, with membership derived from build files.
        var membership: [String: Set<String>] = [:]  // fileRef UUID -> target names
        for target in project.targets {
            for phase in target.buildPhases {
                for buildFile in phase.files ?? [] {
                    if let element = buildFile.file {
                        membership[element.uuid, default: []].insert(target.name)
                    }
                }
            }
        }

        for fileRef in project.pbxproj.fileReferences {
            // Skip product references (built artifacts, not source files).
            if fileRef.sourceTree == .buildProductsDir { continue }
            guard let path = try relativePath(of: fileRef) else { continue }
            snapshots.append(FileSnapshot(
                path: path,
                targets: membership[fileRef.uuid, default: []].sorted(),
                synchronized: false
            ))
        }

        // Synchronized root folders: enumerate the filesystem.
        for root in project.pbxproj.fileSystemSynchronizedRootGroups {
            guard let rootRelative = try relativePath(of: root) else { continue }
            let rootURL = sourceRoot.appendingPathComponent(rootRelative)
            for relative in Self.enumerateSynchronizedFolder(at: rootURL) {
                let targets = membershipInSynchronizedRoot(root, relativePath: relative)
                snapshots.append(FileSnapshot(
                    path: rootRelative + "/" + relative,
                    targets: targets.sorted(),
                    synchronized: true
                ))
            }
        }

        return snapshots.sorted { $0.path < $1.path }
    }

    /// Files under a synchronized folder, relative to it, with bundle-like
    /// directories collapsed to single entries and hidden files skipped.
    static func enumerateSynchronizedFolder(at url: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [String] = []
        let rootPath = url.standardizedFileURL.path
        for case let entry as URL in enumerator {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let isBundle = bundleLikeExtensions.contains(entry.pathExtension.lowercased())
            if isDirectory {
                if isBundle {
                    enumerator.skipDescendants()
                } else {
                    continue
                }
            }
            let path = entry.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            results.append(String(path.dropFirst(rootPath.count + 1)))
        }
        return results.sorted()
    }

    /// Which targets a file inside a synchronized root belongs to, applying
    /// membership exception sets in both directions: owners exclude listed
    /// paths, non-owners include them.
    func membershipInSynchronizedRoot(
        _ root: PBXFileSystemSynchronizedRootGroup, relativePath: String
    ) -> Set<String> {
        var result: Set<String> = []
        let exceptions = root.exceptions?
            .compactMap { $0 as? PBXFileSystemSynchronizedBuildFileExceptionSet } ?? []

        for target in project.targets {
            let owns = (target.fileSystemSynchronizedGroups ?? [])
                .contains { $0 === root }
            let exceptionSet = exceptions.first { $0.target === target }
            let listed = exceptionSet?.membershipExceptions?.contains(relativePath) ?? false
            if owns != listed {
                // owner and not excluded, or non-owner and explicitly included
                result.insert(target.name)
            }
        }
        return result
    }

    // MARK: - Packages

    public func packageSnapshots(root: PBXProject) throws -> [PackageSnapshot] {
        // All product dependencies, with the targets that link them.
        var linked: [(dependency: XCSwiftPackageProductDependency, target: String)] = []
        for target in project.targets {
            guard let native = target as? PBXNativeTarget else { continue }
            for product in native.packageProductDependencies ?? [] {
                linked.append((product, target.name))
            }
        }

        func productSnapshots(_ pairs: [(dependency: XCSwiftPackageProductDependency, target: String)]) -> [PackageProductSnapshot] {
            var targetsByProduct: [String: Set<String>] = [:]
            for (dependency, target) in pairs {
                targetsByProduct[dependency.productName, default: []].insert(target)
            }
            return targetsByProduct
                .map { PackageProductSnapshot(name: $0.key, targets: $0.value.sorted()) }
                .sorted { $0.name < $1.name }
        }

        let remote = root.remotePackages.map { package in
            PackageSnapshot(
                kind: "remote",
                location: package.repositoryURL ?? "",
                requirement: package.versionRequirement.map { String(describing: $0) },
                products: productSnapshots(linked.filter { $0.dependency.package === package })
            )
        }
        // Product dependencies without a package reference come from local
        // packages; they cannot be attributed to a specific one, so they are
        // grouped under each local package only when there is exactly one.
        let unattributed = linked.filter { $0.dependency.package == nil }
        let local = root.localPackages.map { package in
            PackageSnapshot(
                kind: "local",
                location: package.relativePath,
                requirement: nil,
                products: root.localPackages.count == 1 ? productSnapshots(unattributed) : []
            )
        }
        return remote + local
    }
}
