import Foundation

struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Wraps a payload's own keys with the standard `ok`/`action`/`schemaVersion`
/// envelope fields, so every command emits one flat JSON object.
struct Envelope<Payload: Encodable>: Encodable {
    let action: String
    let payload: Payload

    func encode(to encoder: Encoder) throws {
        try payload.encode(to: encoder)
        var container = encoder.container(keyedBy: DynamicKey.self)
        try container.encode(true, forKey: DynamicKey("ok"))
        try container.encode(action, forKey: DynamicKey("action"))
        try container.encode(1, forKey: DynamicKey("schemaVersion"))
    }
}

func printJSON(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8)!)
}

func emit(action: String, json: Bool, payload: some Encodable, human: () -> String) throws {
    if json {
        try printJSON(Envelope(action: action, payload: payload))
    } else {
        let text = human()
        if !text.isEmpty { print(text) }
    }
}
