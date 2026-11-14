import Foundation

/// Generic JSON value so user-defined or AI-added modules can persist custom settings
/// in `~/.config/toolbox/config.json` under `extensions` without altering core structs.
enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
        } else if let numVal = try? container.decode(Double.self) {
            self = .number(numVal)
        } else if let strVal = try? container.decode(String.self) {
            self = .string(strVal)
        } else if let arrVal = try? container.decode([JSONValue].self) {
            self = .array(arrVal)
        } else if let objVal = try? container.decode([String: JSONValue].self) {
            self = .object(objVal)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
