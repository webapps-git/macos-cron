import Foundation

/// Untyped JSON used to decode stored configuration with defaults: fields missing from older
/// JSON are filled from a default-initialized value (`Codable` ignores property defaults).
nonisolated enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

/// A value that has a meaningful default for every stored property.
nonisolated protocol DefaultDecodable: Codable {
    init()
}

nonisolated enum DefaultDecoding {
    /// Decodes `type` from `json`, taking every missing top-level field from `T()`.
    static func decode<T: DefaultDecodable>(_ type: T.Type, from json: JSONValue?) throws -> T {
        let defaults = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(T()))
        var merged: [String: JSONValue] = [:]

        if case .object(let defaultFields) = defaults {
            merged = defaultFields
        }

        if case .object(let storedFields)? = json {
            merged.merge(storedFields) { _, stored in stored }
        }

        return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(JSONValue.object(merged)))
    }

    /// Decodes a JSON array stored as text; an empty string is an empty list.
    static func decodeList<T: DefaultDecodable>(_ type: T.Type, from text: String) -> Result<[T], Error> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return .success([])
        }

        return Result {
            try JSONDecoder()
                .decode([JSONValue].self, from: Data(trimmed.utf8))
                .map { try decode(T.self, from: $0) }
        }
    }

    static func encodeList<T: Encodable>(_ values: [T]) -> String {
        guard let data = try? JSONEncoder().encode(values), let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }

        return text
    }
}
