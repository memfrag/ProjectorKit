import Foundation
import XcodeProj

/// A scalar plist value, as settable from the CLI or library callers.
public enum PlistValue: Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case integer(Int)
    case real(Double)

    /// Infers a type from CLI text: "true"/"false" → bool, an integer literal
    /// → integer, a floating literal → real, else a string.
    public static func parse(_ raw: String) -> PlistValue {
        if raw == "true" { return .bool(true) }
        if raw == "false" { return .bool(false) }
        if let intValue = Int(raw) { return .integer(intValue) }
        if let doubleValue = Double(raw) { return .real(doubleValue) }
        return .string(raw)
    }

    var rawAny: Any {
        switch self {
        case .string(let s): s
        case .bool(let b): b
        case .integer(let i): i
        case .real(let d): d
        }
    }

    var buildSettingValue: BuildSettingValue {
        switch self {
        case .string(let s): .string(s)
        case .bool(let b): .string(b ? "YES" : "NO")
        case .integer(let i): .string(String(i))
        case .real(let d): .string(String(d))
        }
    }
}

public extension ProjectorProject {
    /// Sets a top-level key in a target's Info.plist. If the target has
    /// `GENERATE_INFOPLIST_FILE = YES` (no physical Info.plist file), scalar
    /// string/bool values are routed to the equivalent `INFOPLIST_KEY_<key>`
    /// build setting instead — the mechanism Xcode itself uses. Otherwise edits
    /// the physical file named by `INFOPLIST_FILE`. Idempotent.
    @discardableResult
    func setInfoPlistValue(_ key: String, to value: PlistValue, target targetName: String) throws -> OperationResult {
        let nativeTarget = try nativeTarget(named: targetName)
        guard let configurations = nativeTarget.buildConfigurationList?.buildConfigurations, !configurations.isEmpty else {
            throw ProjectorError.invalidOperation("Target '\(targetName)' has no build configurations")
        }

        let generatesInfoPlist = configurations.allSatisfy {
            $0.buildSettings["GENERATE_INFOPLIST_FILE"]?.stringValue == "YES"
        }
        if generatesInfoPlist {
            switch value {
            case .string, .bool:
                return try setBuildSetting("INFOPLIST_KEY_\(key)", to: value.buildSettingValue, scope: .target(targetName))
            case .integer, .real:
                throw ProjectorError.invalidOperation(
                    "Target '\(targetName)' generates its Info.plist (GENERATE_INFOPLIST_FILE = YES); only string and boolean values can be routed to INFOPLIST_KEY_\(key). Disable generation or edit the physical file to set numeric values.")
            }
        }

        guard let infoPlistPath = configurations.first?.buildSettings["INFOPLIST_FILE"]?.stringValue else {
            throw ProjectorError.invalidOperation(
                "Target '\(targetName)' has neither GENERATE_INFOPLIST_FILE = YES nor an INFOPLIST_FILE setting; nothing to edit.")
        }
        let sourceRoot = xcodeprojPath.deletingLastPathComponent()
        return try setPlistKey(key, to: value, at: sourceRoot.appendingPathComponent(infoPlistPath))
    }

    /// Sets a top-level key in a target's `.entitlements` file, named by the
    /// `CODE_SIGN_ENTITLEMENTS` build setting. The setting must already point
    /// somewhere (set it first via `set build-setting` if the target is new).
    /// Idempotent.
    @discardableResult
    func setEntitlement(_ key: String, to value: PlistValue, target targetName: String) throws -> OperationResult {
        let nativeTarget = try nativeTarget(named: targetName)
        guard let entitlementsPath = nativeTarget.buildConfigurationList?.buildConfigurations
            .first?.buildSettings["CODE_SIGN_ENTITLEMENTS"]?.stringValue
        else {
            throw ProjectorError.invalidOperation(
                "Target '\(targetName)' has no CODE_SIGN_ENTITLEMENTS setting. Set one first, e.g.: set build-setting CODE_SIGN_ENTITLEMENTS \(targetName)/\(targetName).entitlements --target \(targetName)")
        }
        let sourceRoot = xcodeprojPath.deletingLastPathComponent()
        return try setPlistKey(key, to: value, at: sourceRoot.appendingPathComponent(entitlementsPath))
    }

    // MARK: - Shared plist-file editing

    /// Reads, mutates, and deterministically re-serializes (sorted keys) a
    /// plist file at `url`. Values other than the one being set are preserved
    /// via a generic `Any` round-trip through `PropertyListSerialization`, so
    /// arrays/dictionaries/dates/data already in the file are never dropped.
    private func setPlistKey(_ key: String, to value: PlistValue, at url: URL) throws -> OperationResult {
        var dict = Self.readPlistDictionary(at: url)
        dict[key] = value.rawAny
        let newXML = Self.renderPlistXML(dict)
        let originalText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        guard newXML != originalText else { return .alreadySatisfied }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicWriter.write(newXML, to: url, backup: true)

        return .applied(changes: [
            ChangeDescription(kind: "plist", detail: "set \(key) in \(url.lastPathComponent)", target: nil),
        ])
    }

    static func readPlistDictionary(at url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = object as? [String: Any]
        else { return [:] }
        return dict
    }

    static func renderPlistXML(_ dict: [String: Any]) -> String {
        let body = xmlDictBody(dict, indent: "\t")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \(body)</dict>
        </plist>

        """
    }

    private static func xmlDictBody(_ dict: [String: Any], indent: String) -> String {
        dict.keys.sorted().map { key in
            "\(indent)<key>\(xmlEscape(key))</key>\n\(xmlValue(dict[key]!, indent: indent))\n"
        }.joined()
    }

    private static func xmlValue(_ any: Any, indent: String) -> String {
        switch any {
        case let bool as Bool:
            return "\(indent)<\(bool ? "true" : "false")/>"
        case let int as Int:
            return "\(indent)<integer>\(int)</integer>"
        case let double as Double:
            return "\(indent)<real>\(double)</real>"
        case let string as String:
            return "\(indent)<string>\(xmlEscape(string))</string>"
        case let date as Date:
            let formatter = ISO8601DateFormatter()
            return "\(indent)<date>\(formatter.string(from: date))</date>"
        case let data as Data:
            return "\(indent)<data>\n\(indent)\(data.base64EncodedString())\n\(indent)</data>"
        case let array as [Any]:
            guard !array.isEmpty else { return "\(indent)<array/>" }
            let items = array.map { xmlValue($0, indent: indent + "\t") }.joined(separator: "\n")
            return "\(indent)<array>\n\(items)\n\(indent)</array>"
        case let nested as [String: Any]:
            guard !nested.isEmpty else { return "\(indent)<dict/>" }
            return "\(indent)<dict>\n\(xmlDictBody(nested, indent: indent + "\t"))\(indent)</dict>"
        default:
            return "\(indent)<string>\(xmlEscape(String(describing: any)))</string>"
        }
    }

    private static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
