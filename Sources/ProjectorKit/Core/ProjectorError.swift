import Foundation

/// Errors thrown by ProjectorKit. Every case carries enough context to tell the
/// caller what to fix, and maps to a stable CLI exit code.
public enum ProjectorError: Error, CustomStringConvertible, Sendable {
    /// The .xcodeproj (or a file inside it) could not be found or read.
    case projectNotFound(path: String)
    /// The pbxproj exists but could not be parsed.
    case parseFailure(path: String, underlying: String)
    /// The project uses an objectVersion this framework does not know how to
    /// handle safely.
    case unsupportedObjectVersion(Int)
    /// A named entity (target, file, group, scheme, configuration…) was not found.
    case notFound(kind: String, name: String, hint: String?)
    /// Structural validation failed before writing.
    case validationFailed([ValidationIssue])
    /// The project file changed on disk after we loaded it (e.g. Xcode saved).
    case concurrentModification(path: String)
    /// Writing or post-write verification failed.
    case writeFailure(path: String, reason: String)
    /// The requested operation is ambiguous or invalid as specified.
    case invalidOperation(String)

    public var description: String {
        switch self {
        case .projectNotFound(let path):
            return "Project not found at \(path)"
        case .parseFailure(let path, let underlying):
            return "Failed to parse \(path): \(underlying)"
        case .unsupportedObjectVersion(let version):
            return "Unsupported objectVersion \(version). Supported: 50-56, 60, 70, 77. Refusing to guess at a newer format."
        case .notFound(let kind, let name, let hint):
            var message = "\(kind) '\(name)' not found"
            if let hint { message += ". \(hint)" }
            return message
        case .validationFailed(let issues):
            let list = issues.map { "  - \($0.description)" }.joined(separator: "\n")
            return "Project validation failed:\n\(list)"
        case .concurrentModification(let path):
            return "\(path) changed on disk since it was loaded (is Xcode open?). Re-run the command."
        case .writeFailure(let path, let reason):
            return "Failed to write \(path): \(reason)"
        case .invalidOperation(let reason):
            return "Invalid operation: \(reason)"
        }
    }
}

/// A single structural problem found in a project graph.
public struct ValidationIssue: Sendable, Codable, CustomStringConvertible {
    public enum Severity: String, Sendable, Codable {
        case error
        case warning
    }

    public let severity: Severity
    /// Stable machine-readable identifier, e.g. "dangling-reference".
    public let rule: String
    public let message: String
    /// Object reference (UUID) the issue is anchored to, when applicable.
    public let objectReference: String?

    public init(severity: Severity, rule: String, message: String, objectReference: String? = nil) {
        self.severity = severity
        self.rule = rule
        self.message = message
        self.objectReference = objectReference
    }

    public var description: String {
        "[\(severity.rawValue)] \(rule): \(message)" + (objectReference.map { " (\($0))" } ?? "")
    }
}
