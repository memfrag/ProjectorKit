import Foundation
import XcodeProj

public struct SaveOptions: Sendable {
    /// Write a `.projector-backup` sibling before replacing the file.
    public var backup: Bool
    /// Refuse to write if the pbxproj changed on disk since load.
    public var checkConcurrentModification: Bool
    /// After writing, run `xcodebuild -list` and fail the save if it doesn't
    /// succeed. Opt-in: slow, and can fail for reasons unrelated to the edit.
    public var verifyXcodebuild: Bool

    public init(backup: Bool = true, checkConcurrentModification: Bool = true, verifyXcodebuild: Bool = false) {
        self.backup = backup
        self.checkConcurrentModification = checkConcurrentModification
        self.verifyXcodebuild = verifyXcodebuild
    }
}

public struct SaveOutcome: Sendable {
    public let fidelity: Fidelity
    public let diff: DiffReport
    public let changedReferences: [String]
    /// True when the file on disk was actually rewritten.
    public let wroteFile: Bool
    /// Set when `SaveOptions.verifyXcodebuild` was requested and a write happened.
    public let xcodebuildVerification: XcodebuildVerification?
}

/// The result of a dry-run: what `save` would do, without writing.
public struct CheckOutcome: Sendable {
    public let fidelity: Fidelity
    public let diff: DiffReport
    public let changedReferences: [String]
    public var hasChanges: Bool { !diff.isEmpty }
}

public extension ProjectorProject {
    /// Computes the pbxproj text `save` would produce and diffs it against the
    /// pristine text — without writing or validating side effects.
    internal func plannedText() throws -> SurgicalWriter.Result {
        try SurgicalWriter.produce(pristineText: pristineText, mutatedProj: pbxproj)
    }

    /// Dry run: report the pending change without writing.
    func check() throws -> CheckOutcome {
        let result = try plannedText()
        let diff = DiffReport(old: pristineText, new: result.text)
        return CheckOutcome(fidelity: result.fidelity, diff: diff, changedReferences: result.changedReferences)
    }

    /// Validate, then write the pbxproj atomically if anything changed.
    @discardableResult
    func save(options: SaveOptions = SaveOptions()) throws -> SaveOutcome {
        // 1. Structural validation (blocking on errors).
        let issues = ProjectValidator(project: self).validate()
        let errors = issues.filter { $0.severity == .error }
        if !errors.isEmpty {
            throw ProjectorError.validationFailed(errors)
        }

        // 2. Optimistic lock.
        if options.checkConcurrentModification {
            let current = try FileFingerprint(of: pbxprojPath)
            if current != loadedFingerprint {
                throw ProjectorError.concurrentModification(path: pbxprojPath.path)
            }
        }

        // 3. Produce text.
        let result = try plannedText()
        let diff = DiffReport(old: pristineText, new: result.text)

        // 4. Nothing to do?
        if result.fidelity == .none || diff.isEmpty {
            return SaveOutcome(fidelity: .none, diff: diff, changedReferences: [], wroteFile: false, xcodebuildVerification: nil)
        }

        // 5. Atomic write + post-write reparse sanity check.
        try AtomicWriter.write(result.text, to: pbxprojPath, backup: options.backup)
        do {
            _ = try PBXProj(data: Data(result.text.utf8))
        } catch {
            throw ProjectorError.writeFailure(
                path: pbxprojPath.path,
                reason: "written file failed to re-parse: \(error). A backup was kept.")
        }

        // 6. Optional ground-truth check: does Xcode itself accept the file?
        var verification: XcodebuildVerification?
        if options.verifyXcodebuild {
            let outcome = SanityChecks.verifyWithXcodebuild(projectPath: xcodeprojPath)
            verification = outcome
            if !outcome.succeeded {
                throw ProjectorError.writeFailure(
                    path: pbxprojPath.path,
                    reason: "xcodebuild -list failed after write (file was written; a backup was kept):\n\(outcome.output)")
            }
        }

        return SaveOutcome(
            fidelity: result.fidelity, diff: diff,
            changedReferences: result.changedReferences, wroteFile: true,
            xcodebuildVerification: verification)
    }
}
