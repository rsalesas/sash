import Foundation

/// A JSON document as a Swift value. The one representation that crosses the
/// bridge in both directions unchanged: store values, call arguments and
/// results, event payloads.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a JSON value")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
                     ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSONValue {
    /// Converts an object tree produced by `JSONSerialization` (or by WebKit
    /// for a script message body) into a value.
    public init(foundation object: Any?) throws {
        switch object {
        case nil, is NSNull: self = .null
        case let n as NSNumber:
            // CFBoolean is an NSNumber; tell the two apart by the ObjC type.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) }
            else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(try a.map { try JSONValue(foundation: $0) })
        case let o as [String: Any]: self = .object(try o.mapValues { try JSONValue(foundation: $0) })
        case let d as Date: self = .number(d.timeIntervalSince1970 * 1000)
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription:
                "Not a JSON value: \(type(of: object!))"))
        }
    }

    /// The `JSONSerialization` shape, for handing back to WebKit.
    public var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.foundationObject)
        case .object(let o): return o.mapValues(\.foundationObject)
        }
    }

    /// Encodes any `Encodable` into a value.
    public init<T: Encodable>(encoding value: T) throws {
        let data = try JSONEncoder.sash.encode(value)
        self = try JSONDecoder.sash.decode(JSONValue.self, from: data)
    }

    /// Decodes the value into any `Decodable`.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONDecoder.sash.decode(T.self, from: try JSONEncoder.sash.encode(self))
    }

    public var isNull: Bool { if case .null = self { return true } else { return false } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var doubleValue: Double? { if case .number(let n) = self { return n } else { return nil } }
    public var intValue: Int? { doubleValue.flatMap { $0.rounded() == $0 ? Int($0) : nil } }
    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }
    public subscript(index: Int) -> JSONValue? {
        guard let a = arrayValue, a.indices.contains(index) else { return nil }
        return a[index]
    }

    /// Compact JSON text.
    public func serialized() throws -> Data { try JSONEncoder.sash.encode(self) }

    public init(parsing data: Data) throws { self = try JSONDecoder.sash.decode(JSONValue.self, from: data) }
}

extension JSONEncoder {
    /// The one encoder configuration Sash uses everywhere. Deterministic key
    /// order matters for ETags and for readable snapshots.
    public static var sash: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }
}

extension JSONDecoder {
    public static var sash: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }
}
