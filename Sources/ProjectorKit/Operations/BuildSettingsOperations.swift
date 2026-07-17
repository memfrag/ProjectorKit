import Foundation
import XcodeProj

/// A build setting value: a scalar string or a list.
public enum BuildSettingValue: Sendable, Equatable {
    case string(String)
    case array([String])

    var xcodeProjValue: BuildSetting {
        switch self {
        case .string(let value): .string(value)
        case .array(let values): .array(values)
        }
    }

    var display: String {
        switch self {
        case .string(let value): value
        case .array(let values): values.joined(separator: " ")
        }
    }
}

/// Which configurations, at which level, a setting change applies to.
public struct SettingScope: Sendable, Equatable {
    public enum Level: Sendable, Equatable {
        case project
        case target(String)
    }

    public let level: Level
    /// nil means all configurations.
    public let configuration: String?

    public init(level: Level, configuration: String? = nil) {
        self.level = level
        self.configuration = configuration
    }

    public static func project(configuration: String? = nil) -> SettingScope {
        SettingScope(level: .project, configuration: configuration)
    }

    public static func target(_ name: String, configuration: String? = nil) -> SettingScope {
        SettingScope(level: .target(name), configuration: configuration)
    }
}

public extension ProjectorProject {
    /// Sets a build setting across the configurations named by `scope`.
    /// Idempotent: returns `.alreadySatisfied` when every targeted configuration
    /// already holds the value.
    @discardableResult
    func setBuildSetting(_ key: String, to value: BuildSettingValue, scope: SettingScope) throws -> OperationResult {
        let configurations = try targetedConfigurations(scope)
        guard !configurations.isEmpty else {
            throw ProjectorError.notFound(kind: "Configuration", name: scope.configuration ?? "*", hint: nil)
        }

        var changes: [ChangeDescription] = []
        let newValue = value.xcodeProjValue
        for config in configurations {
            if config.buildSettings[key] == newValue { continue }
            config.buildSettings[key] = newValue
            changes.append(ChangeDescription(
                kind: "buildSetting",
                detail: "\(key) = \(value.display) [\(config.name)]",
                target: scope.levelTargetName))
        }
        return changes.isEmpty ? .alreadySatisfied : .applied(changes: changes)
    }

    /// Removes a build setting from the targeted configurations. Idempotent.
    @discardableResult
    func unsetBuildSetting(_ key: String, scope: SettingScope) throws -> OperationResult {
        let configurations = try targetedConfigurations(scope)
        var changes: [ChangeDescription] = []
        for config in configurations where config.buildSettings[key] != nil {
            config.buildSettings.removeValue(forKey: key)
            changes.append(ChangeDescription(
                kind: "buildSetting", detail: "unset \(key) [\(config.name)]",
                target: scope.levelTargetName))
        }
        return changes.isEmpty ? .alreadySatisfied : .applied(changes: changes)
    }

    private func targetedConfigurations(_ scope: SettingScope) throws -> [XCBuildConfiguration] {
        let list: XCConfigurationList?
        switch scope.level {
        case .project:
            list = try rootProject.buildConfigurationList
        case .target(let name):
            list = try target(named: name).buildConfigurationList
        }
        guard let configurations = list?.buildConfigurations else { return [] }
        if let wanted = scope.configuration {
            let matching = configurations.filter { $0.name == wanted }
            if matching.isEmpty {
                throw ProjectorError.notFound(
                    kind: "Configuration", name: wanted,
                    hint: "Available: \(configurations.map(\.name).joined(separator: ", "))")
            }
            return matching
        }
        return configurations
    }
}

private extension SettingScope {
    var levelTargetName: String? {
        if case .target(let name) = level { return name }
        return nil
    }
}
