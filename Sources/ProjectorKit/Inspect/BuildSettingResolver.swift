import Foundation
import XcodeProj

/// Reads build setting values with provenance. Does not expand `$(...)`
/// variable references — it reports where a literal setting is defined and
/// which layer wins, which is what agents need to decide edits.
public struct BuildSettingResolver {
    let project: ProjectorProject

    public init(project: ProjectorProject) {
        self.project = project
    }

    public enum Origin: String, Codable, Sendable {
        case target
        case project
        case xcconfigTarget = "xcconfig-target"
        case xcconfigProject = "xcconfig-project"
    }

    public struct ResolvedValue: Codable, Sendable {
        public let configuration: String
        public let value: String?
        /// Where the winning value came from, nil when unset everywhere.
        public let origin: Origin?

        public init(configuration: String, value: String?, origin: Origin?) {
            self.configuration = configuration
            self.value = value
            self.origin = origin
        }
    }

    /// Resolves `key` for a target across all of its configurations. Layering,
    /// highest priority first: target xcconfig, target build settings, project
    /// xcconfig, project build settings.
    public func resolve(key: String, target targetName: String) throws -> [ResolvedValue] {
        let target = try project.target(named: targetName)
        let root = try project.rootProject
        guard let targetConfigs = target.buildConfigurationList?.buildConfigurations else {
            return []
        }

        return targetConfigs.map { targetConfig in
            let projectConfig = root.buildConfigurationList.buildConfigurations
                .first { $0.name == targetConfig.name }

            if let value = targetConfig.buildSettings[key] {
                return ResolvedValue(configuration: targetConfig.name, value: value.description, origin: .target)
            }
            if let value = xcconfigValue(key: key, configuration: targetConfig) {
                return ResolvedValue(configuration: targetConfig.name, value: value, origin: .xcconfigTarget)
            }
            if let value = projectConfig?.buildSettings[key] {
                return ResolvedValue(configuration: targetConfig.name, value: value.description, origin: .project)
            }
            if let projectConfig, let value = xcconfigValue(key: key, configuration: projectConfig) {
                return ResolvedValue(configuration: targetConfig.name, value: value, origin: .xcconfigProject)
            }
            return ResolvedValue(configuration: targetConfig.name, value: nil, origin: nil)
        }
    }

    /// Reads a build setting straight from a configuration's own dictionary
    /// (no layering), for project-level queries.
    public func projectValues(key: String) throws -> [ResolvedValue] {
        try project.rootProject.buildConfigurationList.buildConfigurations.map { config in
            if let value = config.buildSettings[key] {
                return ResolvedValue(configuration: config.name, value: value.description, origin: .project)
            }
            if let value = xcconfigValue(key: key, configuration: config) {
                return ResolvedValue(configuration: config.name, value: value, origin: .xcconfigProject)
            }
            return ResolvedValue(configuration: config.name, value: nil, origin: nil)
        }
    }

    private func xcconfigValue(key: String, configuration: XCBuildConfiguration) -> String? {
        guard let ref = configuration.baseConfiguration,
              let relative = ref.path
        else { return nil }
        let sourceRoot = project.xcodeprojPath.deletingLastPathComponent()
        let url = sourceRoot.appendingPathComponent(relative)
        guard let config = try? XCConfig(path: .init(url.path)) else { return nil }
        return config.flattenedBuildSettings()[key]?.description
    }
}
