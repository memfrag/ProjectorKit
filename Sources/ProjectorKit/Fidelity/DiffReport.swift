import Foundation

/// A line-level unified diff between two texts, computed with the standard
/// library's `CollectionDifference` (no external dependency, no subprocess).
public struct DiffReport: Sendable {
    public struct Hunk: Sendable {
        public let oldStart: Int
        public let oldCount: Int
        public let newStart: Int
        public let newCount: Int
        public let lines: [String]  // prefixed with " ", "-", or "+"
    }

    public let hunks: [Hunk]
    /// Number of lines removed and added, respectively.
    public let removed: Int
    public let added: Int

    public var isEmpty: Bool { removed == 0 && added == 0 }

    public init(old: String, new: String, context: Int = 3) {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let diff = newLines.difference(from: oldLines)

        var removedSet: [Int: String] = [:]
        var insertedSet: [Int: String] = [:]
        for change in diff {
            switch change {
            case let .remove(offset, element, _): removedSet[offset] = element
            case let .insert(offset, element, _): insertedSet[offset] = element
            }
        }
        self.removed = removedSet.count
        self.added = insertedSet.count

        // Build an aligned edit script to render unified hunks.
        var ops: [(kind: Character, text: String, oldLine: Int, newLine: Int)] = []
        var oi = 0, ni = 0
        while oi < oldLines.count || ni < newLines.count {
            if let removedLine = removedSet[oi], insertedSet[ni] == nil || oldLines.count - oi > newLines.count - ni {
                ops.append(("-", removedLine, oi, ni)); oi += 1
            } else if let insertedLine = insertedSet[ni] {
                ops.append(("+", insertedLine, oi, ni)); ni += 1
            } else if removedSet[oi] != nil {
                ops.append(("-", oldLines[oi], oi, ni)); oi += 1
            } else {
                let text = oi < oldLines.count ? oldLines[oi] : ""
                ops.append((" ", text, oi, ni)); oi += 1; ni += 1
            }
        }

        self.hunks = DiffReport.hunks(from: ops, context: context)
    }

    private static func hunks(
        from ops: [(kind: Character, text: String, oldLine: Int, newLine: Int)], context: Int
    ) -> [Hunk] {
        let changeIndices = ops.indices.filter { ops[$0].kind != " " }
        guard !changeIndices.isEmpty else { return [] }

        // Group change indices whose gaps are within 2*context.
        var groups: [[Int]] = []
        for index in changeIndices {
            if var last = groups.last, let lastIndex = last.last, index - lastIndex <= context * 2 {
                last.append(index); groups[groups.count - 1] = last
            } else {
                groups.append([index])
            }
        }

        return groups.map { group in
            let start = max(0, group.first! - context)
            let end = min(ops.count - 1, group.last! + context)
            let slice = ops[start...end]
            let lines = slice.map { "\($0.kind)\($0.text)" }
            let oldLinesInHunk = slice.filter { $0.kind != "+" }.count
            let newLinesInHunk = slice.filter { $0.kind != "-" }.count
            return Hunk(
                oldStart: ops[start].oldLine + 1, oldCount: oldLinesInHunk,
                newStart: ops[start].newLine + 1, newCount: newLinesInHunk,
                lines: lines)
        }
    }

    /// Unified-diff text with `@@` headers.
    public func unified() -> String {
        hunks.map { hunk in
            let header = "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
            return ([header] + hunk.lines).joined(separator: "\n")
        }.joined(separator: "\n")
    }
}
