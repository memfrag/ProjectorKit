import Foundation

/// The outcome of a single mutation. Idempotency is a first-class result, not
/// an error: applying an operation whose end-state already holds returns
/// `.alreadySatisfied`.
public enum OperationResult: Sendable, Equatable {
    case applied(changes: [ChangeDescription])
    case alreadySatisfied

    public var isApplied: Bool {
        if case .applied = self { return true }
        return false
    }

    public var changes: [ChangeDescription] {
        if case .applied(let changes) = self { return changes }
        return []
    }
}

/// One concrete change made to the project, suitable for JSON output.
public struct ChangeDescription: Sendable, Equatable, Codable {
    /// Machine-readable kind, e.g. "fileReference", "buildFile", "target",
    /// "buildSetting", "packageReference", "scheme", "fileSystem".
    public let kind: String
    /// Human-readable description of the change.
    public let detail: String
    /// Target name this change applies to, when applicable.
    public let target: String?

    public init(kind: String, detail: String, target: String? = nil) {
        self.kind = kind
        self.detail = detail
        self.target = target
    }
}
