import Foundation
import XcodeProj

/// Declarative description of a target to create. Deliberately covers the
/// common product types with sane defaults rather than exposing every Xcode
/// knob — callers needing something exotic can fall back to the `xcodeProj`
/// escape hatch on `ProjectorProject`.
public struct TargetSpec: Sendable {
    public enum ProductType: String, Sendable, CaseIterable {
        case application
        case framework
        case staticFramework
        case staticLibrary
        case dynamicLibrary
        case bundle
        case unitTestBundle
        case uiTestBundle
        case appExtension
        case commandLineTool
        case xpcService

        var xcodeProjType: PBXProductType {
            switch self {
            case .application: .application
            case .framework: .framework
            case .staticFramework: .staticFramework
            case .staticLibrary: .staticLibrary
            case .dynamicLibrary: .dynamicLibrary
            case .bundle: .bundle
            case .unitTestBundle: .unitTestBundle
            case .uiTestBundle: .uiTestBundle
            case .appExtension: .appExtension
            case .commandLineTool: .commandLineTool
            case .xpcService: .xpcService
            }
        }

        /// (UTI, product file extension). Matches what Xcode itself writes into
        /// `explicitFileType`/`lastKnownFileType` on the product reference.
        var fileType: (uti: String, extension: String) {
            switch self {
            case .application: ("wrapper.application", "app")
            case .framework, .staticFramework: ("wrapper.framework", "framework")
            case .staticLibrary: ("archive.ar", "a")
            case .dynamicLibrary: ("compiled.mach-o.dylib", "dylib")
            case .bundle: ("wrapper.cfbundle", "bundle")
            case .unitTestBundle, .uiTestBundle: ("wrapper.cfbundle", "xctest")
            case .appExtension: ("wrapper.app-extension", "appex")
            case .commandLineTool: ("compiled.mach-o.executable", "")
            case .xpcService: ("wrapper.xpc-service", "xpc")
            }
        }

        var isTestBundle: Bool { self == .unitTestBundle || self == .uiTestBundle }
    }

    public enum Platform: String, Sendable {
        case macOS, iOS, tvOS, watchOS

        var sdkroot: String {
            switch self {
            case .macOS: "macosx"
            case .iOS: "iphoneos"
            case .tvOS: "appletvos"
            case .watchOS: "watchos"
            }
        }

        var deploymentTargetKey: String {
            switch self {
            case .macOS: "MACOSX_DEPLOYMENT_TARGET"
            case .iOS: "IPHONEOS_DEPLOYMENT_TARGET"
            case .tvOS: "TVOS_DEPLOYMENT_TARGET"
            case .watchOS: "WATCHOS_DEPLOYMENT_TARGET"
            }
        }
    }

    public var name: String
    public var productType: ProductType
    public var platform: Platform
    public var bundleIdentifier: String?
    public var deploymentTarget: String?
    /// For unit/UI test bundles: the app target to host the tests, if any.
    public var testHostTarget: String?

    public init(
        name: String, productType: ProductType, platform: Platform = .macOS,
        bundleIdentifier: String? = nil, deploymentTarget: String? = nil,
        testHostTarget: String? = nil
    ) {
        self.name = name
        self.productType = productType
        self.platform = platform
        self.bundleIdentifier = bundleIdentifier
        self.deploymentTarget = deploymentTarget
        self.testHostTarget = testHostTarget
    }
}

public extension ProjectorProject {
    /// Creates a new target with build configurations, a product reference, and
    /// the standard build phases for its product type. Idempotent: if a target
    /// with this name already exists, returns `.alreadySatisfied` when its
    /// product type matches, else throws.
    @discardableResult
    func addTarget(_ spec: TargetSpec) throws -> OperationResult {
        if let existing = targets.first(where: { $0.name == spec.name }) {
            let existingType = (existing as? PBXNativeTarget)?.productType
            if existingType == spec.productType.xcodeProjType {
                return .alreadySatisfied
            }
            throw ProjectorError.invalidOperation(
                "Target '\(spec.name)' already exists with a different product type (\(existingType?.rawValue ?? "unknown"))")
        }

        let root = try rootProject
        var changes: [ChangeDescription] = []

        // Product file reference, in the Products group.
        let productName = spec.name + (spec.productType.fileType.extension.isEmpty
            ? "" : ".\(spec.productType.fileType.extension)")
        let productRef = PBXFileReference(
            sourceTree: .buildProductsDir,
            explicitFileType: spec.productType.fileType.uti,
            path: productName,
            includeInIndex: false)
        pbxproj.add(object: productRef)
        productsGroup(of: root).children.append(productRef)

        // Build configurations.
        let configList = try makeConfigurationList(for: spec)

        // Build phases.
        var phases: [PBXBuildPhase] = []
        let sources = PBXSourcesBuildPhase()
        pbxproj.add(object: sources); phases.append(sources)
        let frameworks = PBXFrameworksBuildPhase()
        pbxproj.add(object: frameworks); phases.append(frameworks)
        if spec.productType != .commandLineTool, spec.productType != .staticLibrary {
            let resources = PBXResourcesBuildPhase()
            pbxproj.add(object: resources); phases.append(resources)
        }

        let target = PBXNativeTarget(
            name: spec.name, buildConfigurationList: configList, buildPhases: phases,
            productName: spec.name, product: productRef, productType: spec.productType.xcodeProjType)
        pbxproj.add(object: target)
        root.targets.append(target)
        changes.append(ChangeDescription(kind: "target", detail: "create \(spec.productType.rawValue) target", target: spec.name))

        if spec.productType.isTestBundle, let hostName = spec.testHostTarget {
            let hostResult = try addDependency(target: spec.name, on: hostName)
            changes.append(contentsOf: hostResult.changes)
        }

        return .applied(changes: changes)
    }

    /// Removes a target: its native target object, product reference, and any
    /// dependencies other targets hold on it.
    @discardableResult
    func removeTarget(_ name: String) throws -> OperationResult {
        guard let victim = targets.first(where: { $0.name == name }) else {
            return .alreadySatisfied
        }
        var changes: [ChangeDescription] = []
        let root = try rootProject

        for other in targets {
            let before = other.dependencies.count
            other.dependencies.removeAll { $0.target === victim }
            if other.dependencies.count != before {
                changes.append(ChangeDescription(kind: "dependency", detail: "drop dependency on \(name)", target: other.name))
            }
        }

        if let native = victim as? PBXNativeTarget, let product = native.product {
            productsGroup(of: root).children.removeAll { $0 === product }
            pbxproj.delete(object: product)
        }
        root.targets.removeAll { $0 === victim }
        pbxproj.delete(object: victim)
        changes.append(ChangeDescription(kind: "target", detail: "remove target", target: name))

        return .applied(changes: changes)
    }

    private func productsGroup(of root: PBXProject) -> PBXGroup {
        root.productsGroup ?? root.mainGroup
    }

    private func makeConfigurationList(for spec: TargetSpec) throws -> XCConfigurationList {
        let projectConfigNames = try rootProject.buildConfigurationList.buildConfigurations.map(\.name)
        let names = projectConfigNames.isEmpty ? ["Debug", "Release"] : projectConfigNames

        var settings: BuildSettings = [
            "PRODUCT_NAME": .string("$(TARGET_NAME)"),
            "SDKROOT": .string(spec.platform.sdkroot),
            "SWIFT_VERSION": .string("6.0"),
        ]
        if let deploymentTarget = spec.deploymentTarget {
            settings[spec.platform.deploymentTargetKey] = .string(deploymentTarget)
        }
        if spec.productType != .commandLineTool, spec.productType != .staticLibrary, spec.productType != .dynamicLibrary {
            settings["GENERATE_INFOPLIST_FILE"] = .string("YES")
        }
        if let bundleIdentifier = spec.bundleIdentifier {
            settings["PRODUCT_BUNDLE_IDENTIFIER"] = .string(bundleIdentifier)
        }
        switch spec.productType {
        case .framework, .staticFramework:
            settings["DEFINES_MODULE"] = .string("YES")
            settings["SKIP_INSTALL"] = .string("YES")
            if spec.productType == .staticFramework {
                settings["MACH_O_TYPE"] = .string("staticlib")
            }
        case .unitTestBundle, .uiTestBundle:
            if let hostName = spec.testHostTarget, spec.productType == .unitTestBundle {
                settings["TEST_HOST"] = .string("$(BUILT_PRODUCTS_DIR)/\(hostName).app/Contents/MacOS/\(hostName)")
                settings["BUNDLE_LOADER"] = .string("$(TEST_HOST)")
            }
        case .commandLineTool:
            settings["CODE_SIGN_IDENTITY"] = .string("-")
        default:
            break
        }

        let configurations = names.map { name in
            XCBuildConfiguration(name: name, buildSettings: settings)
        }
        configurations.forEach { pbxproj.add(object: $0) }
        let list = XCConfigurationList(buildConfigurations: configurations, defaultConfigurationName: names.last)
        pbxproj.add(object: list)
        return list
    }
}
