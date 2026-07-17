import Foundation
import XcodeProj

/// How a save was produced.
public enum Fidelity: String, Sendable, Codable {
    /// Unchanged objects kept their original bytes; only changed object blocks
    /// were spliced. This is the goal.
    case surgical
    /// The whole pbxproj was re-serialized in XcodeProj's style (a large but
    /// valid diff). Used when the surgical splice could not be verified.
    case reserialize
    /// Nothing changed; output is byte-identical to input.
    case none
}

/// Produces new pbxproj text from a pristine text plus a mutated graph, keeping
/// the diff confined to objects that actually changed.
///
/// Strategy: serialize both the pristine graph (`N0`) and the mutated graph
/// (`N1`) in the same pinned style, diff them at object granularity, then splice
/// only the changed object blocks into the pristine on-disk text `T`. The result
/// is verified by re-parsing and re-serializing: it must match `N1` exactly, or
/// the writer falls back to emitting `N1` wholesale.
struct SurgicalWriter {
    struct Result {
        let text: String
        let fidelity: Fidelity
        /// References whose blocks were added, removed, or modified.
        let changedReferences: [String]
    }

    /// - Parameters:
    ///   - pristineText: the exact bytes currently on disk (`T`).
    ///   - mutatedProj: the working graph after intent operations.
    static func produce(pristineText T: String, mutatedProj: PBXProj) throws -> Result {
        let n1 = try SerializationStyle.serialize(mutatedProj)

        // The project name lives in the XcodeProj wrapper, not the pbxproj text;
        // it is only stamped onto `rootObject.name` at load/write time. A bare
        // `PBXProj(data:)` reparse leaves it empty, which would perturb the
        // `Build configuration list for PBXProject "<name>"` comments. Carry the
        // mutated graph's name onto every reparse so all serializations share
        // the same naming context.
        let projectName = try? mutatedProj.rootProject()?.name

        // Fast path: mutated graph serializes to the same as a fresh parse of T
        // ⇒ nothing changed semantically.
        let n0 = try serialize(dataOf: T, projectName: projectName)
        if n0 == n1 {
            return Result(text: T, fidelity: .none, changedReferences: [])
        }

        // Attempt the surgical splice; any failure falls back to N1.
        do {
            let spliced = try splice(T: T, n0: n0, n1: n1)
            // Verify: reparse the spliced text and reserialize; it must be
            // byte-identical to the intended mutated serialization.
            let verifyText = try serialize(dataOf: spliced.text, projectName: projectName)
            if verifyText == n1 {
                return spliced
            }
            if ProcessInfo.processInfo.environment["PROJECTOR_DEBUG_FIDELITY"] != nil {
                let diff = DiffReport(old: verifyText, new: n1)
                FileHandle.standardError.write(Data("[fidelity] verify mismatch:\n\(diff.unified())\n".utf8))
            }
        } catch {
            if ProcessInfo.processInfo.environment["PROJECTOR_DEBUG_FIDELITY"] != nil {
                FileHandle.standardError.write(Data("[fidelity] splice threw: \(error)\n".utf8))
            }
        }

        return Result(text: n1, fidelity: .reserialize, changedReferences: [])
    }

    /// Parses pbxproj text and serializes it with the pinned style, stamping the
    /// project name first so comment generation matches the loaded graph.
    private static func serialize(dataOf text: String, projectName: String?) throws -> String {
        let proj = try PBXProj(data: Data(text.utf8))
        if let projectName, let root = try? proj.rootProject() {
            root.name = projectName
        }
        return try SerializationStyle.serialize(proj)
    }

    // MARK: - Splice

    private static func splice(T: String, n0: String, n1: String) throws -> Result {
        let indexT = try PBXTextIndex(text: T)
        let indexN0 = try PBXTextIndex(text: n0)
        let indexN1 = try PBXTextIndex(text: n1)

        // Header and trailer must be unchanged for a surgical splice; otherwise
        // (objectVersion / rootObject changes) fall back.
        let headerN0 = String(indexN0.chars[0..<indexN0.objectsBodyStart])
        let headerN1 = String(indexN1.chars[0..<indexN1.objectsBodyStart])
        let trailerN0 = String(indexN0.chars[indexN0.objectsBodyEnd...])
        let trailerN1 = String(indexN1.chars[indexN1.objectsBodyEnd...])
        guard headerN0 == headerN1, trailerN0 == trailerN1 else {
            throw SpliceError.headerOrTrailerChanged
        }

        let refsN0 = Set(indexN0.entries.keys)
        let refsN1 = Set(indexN1.entries.keys)
        let addedRefs = refsN1.subtracting(refsN0)
        let removedRefs = refsN0.subtracting(refsN1)
        var modifiedRefs: Set<String> = []
        for ref in refsN0.intersection(refsN1) {
            let b0 = indexN0.substring(indexN0.entries[ref]!.range)
            let b1 = indexN1.substring(indexN1.entries[ref]!.range)
            if b0 != b1 { modifiedRefs.insert(ref) }
        }

        var changedReferences = Array(addedRefs) + Array(removedRefs) + Array(modifiedRefs)

        // Build edits against T. Each edit is a (range in T, replacement).
        var edits: [(range: Range<Int>, replacement: String)] = []

        let isasT = Set(indexT.sections.map(\.isa))
        let isasN1 = Set(indexN1.sections.map(\.isa))

        // 1. Sections present in both, that changed → rebuild content region.
        for sectionN1 in indexN1.sections where isasT.contains(sectionN1.isa) {
            guard let sectionT = indexT.sections.first(where: { $0.isa == sectionN1.isa }) else { continue }
            let refsHere = Set(sectionN1.entryReferences)
            let refsThere = Set(sectionT.entryReferences)
            let changed = refsHere != refsThere || sectionN1.entryReferences.contains { modifiedRefs.contains($0) }
            guard changed else { continue }

            var rebuilt = ""
            for ref in sectionN1.entryReferences {
                if let entryT = indexT.entries[ref], !modifiedRefs.contains(ref) {
                    rebuilt += indexT.substring(entryT.range)
                } else {
                    rebuilt += indexN1.substring(indexN1.entries[ref]!.range)
                }
            }
            let region = sectionT.beginLine.upperBound..<sectionT.endLine.lowerBound
            edits.append((region, rebuilt))
        }

        // 2. Sections new in N1 → insert whole section at the right position.
        for sectionN1 in indexN1.sections where !isasT.contains(sectionN1.isa) {
            let blocks = sectionN1.entryReferences
                .map { indexN1.substring(indexN1.entries[$0]!.range) }
                .joined()
            let sectionText = "/* Begin \(sectionN1.isa) section */\n" + blocks + "/* End \(sectionN1.isa) section */\n"
            if let insertion = insertionForNewSection(indexT: indexT, newISA: sectionN1.isa, sectionText: sectionText) {
                edits.append(insertion)
            } else {
                throw SpliceError.cannotPlaceSection(sectionN1.isa)
            }
        }

        // 3. Sections removed entirely → delete section and a trailing blank line.
        for sectionT in indexT.sections where !isasN1.contains(sectionT.isa) {
            var end = sectionT.endLine.upperBound
            if end < indexT.chars.count, indexT.chars[end] == "\n" { end += 1 }  // trailing blank line
            edits.append((sectionT.beginLine.lowerBound..<end, ""))
        }

        // Apply edits back-to-front so earlier offsets stay valid.
        edits.sort { $0.range.lowerBound > $1.range.lowerBound }
        // Guard against overlap (a bug would corrupt output).
        for i in 1..<max(edits.count, 1) where i < edits.count {
            if edits[i].range.upperBound > edits[i - 1].range.lowerBound {
                throw SpliceError.overlappingEdits
            }
        }

        var chars = indexT.chars
        for edit in edits {
            chars.replaceSubrange(edit.range, with: Array(edit.replacement))
        }

        changedReferences.sort()
        return Result(text: String(chars), fidelity: .surgical, changedReferences: changedReferences)
    }

    /// Computes an insertion edit for a brand-new section, placing it in
    /// alphabetical-by-ISA order to match Xcode and XcodeProj.
    private static func insertionForNewSection(
        indexT: PBXTextIndex, newISA: String, sectionText: String
    ) -> (range: Range<Int>, replacement: String)? {
        // Insert before the first existing section whose ISA sorts after newISA.
        if let next = indexT.sections.first(where: { $0.isa > newISA }) {
            let pos = next.beginLine.lowerBound
            return (pos..<pos, sectionText + "\n")
        }
        // Otherwise it sorts last: insert just before the objects-closing brace,
        // preceded by a blank line.
        let pos = indexT.objectsBodyEnd
        return (pos..<pos, "\n" + sectionText)
    }

    enum SpliceError: Error {
        case headerOrTrailerChanged
        case cannotPlaceSection(String)
        case overlappingEdits
    }
}
