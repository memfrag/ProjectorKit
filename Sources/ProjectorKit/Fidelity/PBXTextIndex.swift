import Foundation

/// A string-aware structural index of a `project.pbxproj`'s text. It records the
/// byte span of the header, of each `/* Begin/End <ISA> section */`, and of each
/// object entry keyed by its reference — without interpreting values.
///
/// Working unit is `[Character]` (extended grapheme clusters), which rejoins to
/// the exact original text via `String(_:)`, so ranges can be spliced with
/// byte-for-byte fidelity.
///
/// The scanner is deliberately conservative: anything it cannot confidently
/// index makes `init` throw, which the writer treats as a signal to fall back to
/// full re-serialization rather than risk a bad splice.
struct PBXTextIndex {
    struct Entry {
        let reference: String
        let isa: String
        /// Half-open range over `chars`, covering the entry's leading
        /// indentation through its trailing newline.
        let range: Range<Int>
    }

    struct Section {
        let isa: String
        /// Range of the `/* Begin <ISA> section */` line (incl. leading blank
        /// line handling is left to the caller; this is the comment line only).
        let beginLine: Range<Int>
        /// Range of the `/* End <ISA> section */` line.
        let endLine: Range<Int>
        /// References of entries in this section, in file order.
        var entryReferences: [String]
    }

    let chars: [Character]
    /// Index just past the newline following `objects = {`.
    let objectsBodyStart: Int
    /// Index of the start of the line that closes the objects dict (`\t};`).
    let objectsBodyEnd: Int
    private(set) var sections: [Section]
    private(set) var entries: [String: Entry]
    /// Section order as it appears in the file.
    private(set) var sectionOrder: [String]

    enum IndexError: Error, CustomStringConvertible {
        case objectsBlockNotFound
        case malformedEntry(at: Int)
        case unterminatedString(at: Int)
        case unbalancedBraces
        case duplicateReference(String)

        var description: String {
            switch self {
            case .objectsBlockNotFound: "could not locate the objects block"
            case .malformedEntry(let at): "malformed object entry near character \(at)"
            case .unterminatedString(let at): "unterminated string near character \(at)"
            case .unbalancedBraces: "unbalanced braces in objects block"
            case .duplicateReference(let ref): "duplicate object reference \(ref)"
            }
        }
    }

    init(text: String) throws {
        let chars = Array(text)
        self.chars = chars

        guard let (bodyStart, _) = Self.locateObjectsOpen(chars) else {
            throw IndexError.objectsBlockNotFound
        }
        self.objectsBodyStart = bodyStart

        var sections: [Section] = []
        var sectionOrder: [String] = []
        var entries: [String: Entry] = [:]
        var currentSectionISA: String?
        var currentSectionEntries: [String] = []
        var currentSectionBegin: Range<Int>?

        var i = bodyStart
        while i < chars.count {
            // Skip blank space at the start of significant scanning, but do it
            // line-aware so we can measure entry leading indentation.
            let lineStart = i
            let contentStart = Self.skipInlineWhitespace(chars, from: i)

            if contentStart >= chars.count {
                break
            }

            let c = chars[contentStart]

            // Blank line: advance past the newline and continue.
            if c == "\n" {
                i = contentStart + 1
                continue
            }

            // A `}` at line start closes the objects dict.
            if c == "}" {
                self.objectsBodyEnd = lineStart
                self.sections = sections
                self.entries = entries
                self.sectionOrder = sectionOrder
                return
            }

            // Section markers.
            if let (isa, kind) = Self.parseSectionComment(chars, from: contentStart) {
                let lineRange = lineStart..<Self.endOfLineInclusive(chars, from: contentStart)
                switch kind {
                case .begin:
                    currentSectionISA = isa
                    currentSectionEntries = []
                    currentSectionBegin = lineRange
                case .end:
                    guard let beginRange = currentSectionBegin, currentSectionISA == isa else {
                        throw IndexError.malformedEntry(at: contentStart)
                    }
                    sections.append(Section(
                        isa: isa, beginLine: beginRange, endLine: lineRange,
                        entryReferences: currentSectionEntries))
                    sectionOrder.append(isa)
                    currentSectionISA = nil
                    currentSectionBegin = nil
                    currentSectionEntries = []
                }
                i = lineRange.upperBound
                continue
            }

            // Otherwise: an object entry.
            let (reference, isa, entryEnd) = try Self.parseEntry(chars, lineStart: lineStart, contentStart: contentStart)
            if entries[reference] != nil {
                throw IndexError.duplicateReference(reference)
            }
            entries[reference] = Entry(reference: reference, isa: isa, range: lineStart..<entryEnd)
            if currentSectionISA != nil {
                currentSectionEntries.append(reference)
            }
            i = entryEnd
        }

        throw IndexError.objectsBlockNotFound
    }

    // MARK: - Reconstruction

    func text() -> String { String(chars) }

    func substring(_ range: Range<Int>) -> String { String(chars[range]) }

    // MARK: - Locating the objects block

    /// Finds the `objects = {` opener and returns (index just past its newline,
    /// index of the opening brace).
    private static func locateObjectsOpen(_ chars: [Character]) -> (bodyStart: Int, brace: Int)? {
        // Scan lines for one whose trimmed content is exactly `objects = {`.
        var i = 0
        while i < chars.count {
            let lineEnd = endOfLineInclusive(chars, from: i)
            let line = String(chars[i..<lineEnd])
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "objects = {" {
                guard let brace = chars[i..<lineEnd].firstIndex(of: "{") else { return nil }
                return (lineEnd, brace)
            }
            i = lineEnd
        }
        return nil
    }

    // MARK: - Entry parsing

    /// Parses one `<ref> [/* comment */] = { ... };` entry. Returns the
    /// reference, its ISA, and the index just past the entry's trailing newline.
    private static func parseEntry(_ chars: [Character], lineStart: Int, contentStart: Int) throws
        -> (reference: String, isa: String, end: Int)
    {
        var i = contentStart
        let reference = try readReferenceToken(chars, from: &i)

        // Skip whitespace, an optional `/* comment */`, whitespace, then `=`.
        i = skipWhitespaceAndComments(chars, from: i)
        guard i < chars.count, chars[i] == "=" else { throw IndexError.malformedEntry(at: i) }
        i += 1
        i = skipWhitespaceAndComments(chars, from: i)
        guard i < chars.count, chars[i] == "{" else { throw IndexError.malformedEntry(at: i) }

        // Scan the balanced `{ ... }`.
        let afterBrace = try scanBalancedBraces(chars, openBrace: i)
        i = afterBrace
        // Expect a terminating `;`.
        i = skipInlineWhitespace(chars, from: i)
        guard i < chars.count, chars[i] == ";" else { throw IndexError.malformedEntry(at: i) }
        i += 1
        let end = endOfLineInclusive(chars, from: i)

        let isa = extractISA(chars, entryStart: contentStart, entryEnd: end) ?? "PBXObject"
        return (reference, isa, end)
    }

    /// Reads a reference token: either a bare identifier/hex run or a quoted
    /// string (rare). Advances `i` past it.
    private static func readReferenceToken(_ chars: [Character], from i: inout Int) throws -> String {
        guard i < chars.count else { throw IndexError.malformedEntry(at: i) }
        if chars[i] == "\"" {
            let start = i
            i += 1
            while i < chars.count {
                if chars[i] == "\\" { i += 2; continue }
                if chars[i] == "\"" { i += 1; return String(chars[start..<i]) }
                i += 1
            }
            throw IndexError.unterminatedString(at: start)
        }
        let start = i
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace || c == "=" || c == "/" { break }
            i += 1
        }
        guard i > start else { throw IndexError.malformedEntry(at: i) }
        return String(chars[start..<i])
    }

    /// Extracts the `isa = <ISA>;` value from within an entry's text.
    private static func extractISA(_ chars: [Character], entryStart: Int, entryEnd: Int) -> String? {
        let text = String(chars[entryStart..<entryEnd])
        guard let range = text.range(of: "isa = ") else { return nil }
        let after = text[range.upperBound...]
        let value = after.prefix { $0 != ";" && !$0.isWhitespace }
        return value.isEmpty ? nil : String(value)
    }

    // MARK: - Scanning primitives

    /// Scans from an opening `{` to just past its matching `}`, honoring strings
    /// and `/* */` comments so braces inside them are ignored.
    private static func scanBalancedBraces(_ chars: [Character], openBrace: Int) throws -> Int {
        var depth = 0
        var i = openBrace
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                i = try skipString(chars, from: i)
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i = skipBlockComment(chars, from: i)
                continue
            }
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { return i + 1 }
            }
            i += 1
        }
        throw IndexError.unbalancedBraces
    }

    /// From an opening quote, returns the index just past the closing quote.
    private static func skipString(_ chars: [Character], from i: Int) throws -> Int {
        var j = i + 1
        while j < chars.count {
            if chars[j] == "\\" { j += 2; continue }
            if chars[j] == "\"" { return j + 1 }
            j += 1
        }
        throw IndexError.unterminatedString(at: i)
    }

    /// From `/*`, returns the index just past the closing `*/` (or end).
    private static func skipBlockComment(_ chars: [Character], from i: Int) -> Int {
        var j = i + 2
        while j + 1 < chars.count {
            if chars[j] == "*", chars[j + 1] == "/" { return j + 2 }
            j += 1
        }
        return chars.count
    }

    private static func skipInlineWhitespace(_ chars: [Character], from i: Int) -> Int {
        var j = i
        while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
        return j
    }

    private static func skipWhitespaceAndComments(_ chars: [Character], from i: Int) -> Int {
        var j = i
        while j < chars.count {
            let c = chars[j]
            if c == " " || c == "\t" || c == "\n" || c == "\r" { j += 1; continue }
            if c == "/", j + 1 < chars.count, chars[j + 1] == "*" {
                j = skipBlockComment(chars, from: j)
                continue
            }
            break
        }
        return j
    }

    /// Index just past the next newline at or after `i` (or end of input).
    private static func endOfLineInclusive(_ chars: [Character], from i: Int) -> Int {
        var j = i
        while j < chars.count {
            if chars[j] == "\n" { return j + 1 }
            j += 1
        }
        return chars.count
    }

    // MARK: - Section comments

    private enum SectionKind { case begin, end }

    /// If a `/* Begin <ISA> section */` or `/* End <ISA> section */` starts at
    /// `i`, returns its ISA and kind.
    private static func parseSectionComment(_ chars: [Character], from i: Int) -> (isa: String, kind: SectionKind)? {
        let lineEnd = endOfLineInclusive(chars, from: i)
        let line = String(chars[i..<lineEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        for (prefix, kind) in [("/* Begin ", SectionKind.begin), ("/* End ", SectionKind.end)] {
            if line.hasPrefix(prefix), line.hasSuffix(" section */") {
                let inner = line.dropFirst(prefix.count).dropLast(" section */".count)
                let isa = String(inner)
                if !isa.isEmpty { return (isa, kind) }
            }
        }
        return nil
    }
}
