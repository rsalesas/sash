import Foundation

/// Decodes `Decodable` types straight from a `JSONValue`, and in strict mode
/// refuses objects with fields the type never asked for.
///
/// Strictness is what makes `invalid-args` honest: a page that misspells an
/// argument gets an error rather than a silently ignored field.
public struct JSONValueDecoder {
    public var strict: Bool

    public init(strict: Bool = false) {
        self.strict = strict
    }

    public func decode<T: Decodable>(_ type: T.Type = T.self, from value: JSONValue) throws -> T {
        let tracker = Tracker()
        let decoder = _Decoder(value: value, codingPath: [], strict: strict, tracker: tracker)
        let result = try T(from: decoder)
        if strict, let unknown = tracker.firstUnknown() {
            throw DecodingError.dataCorrupted(.init(codingPath: unknown.path, debugDescription: "unknown field \(unknown.key)"))
        }
        return result
    }

    /// Records which keys each object had and which were touched.
    final class Tracker {
        struct Visit { let path: [any CodingKey]; var present: Set<String>; var touched: Set<String>; var all = false }
        var visits: [Visit] = []

        func open(_ path: [any CodingKey], keys: Set<String>) -> Int {
            visits.append(Visit(path: path, present: keys, touched: []))
            return visits.count - 1
        }
        func touch(_ index: Int, _ key: String) { visits[index].touched.insert(key) }
        func touchAll(_ index: Int) { visits[index].all = true }

        func firstUnknown() -> (path: [any CodingKey], key: String)? {
            for v in visits where !v.all {
                if let k = v.present.subtracting(v.touched).sorted().first { return (v.path, k) }
            }
            return nil
        }
    }

    struct _Decoder: Decoder {
        let value: JSONValue
        let codingPath: [any CodingKey]
        let strict: Bool
        let tracker: Tracker
        var userInfo: [CodingUserInfoKey: Any] { [:] }

        func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
            guard case .object(let o) = value else {
                throw DecodingError.typeMismatch([String: JSONValue].self, .init(codingPath: codingPath, debugDescription: "expected an object"))
            }
            let index = tracker.open(codingPath, keys: Set(o.keys))
            return KeyedDecodingContainer(Keyed(object: o, codingPath: codingPath, strict: strict, tracker: tracker, index: index))
        }

        func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
            guard case .array(let a) = value else {
                throw DecodingError.typeMismatch([JSONValue].self, .init(codingPath: codingPath, debugDescription: "expected an array"))
            }
            return Unkeyed(array: a, codingPath: codingPath, strict: strict, tracker: tracker)
        }

        func singleValueContainer() throws -> any SingleValueDecodingContainer {
            Single(value: value, codingPath: codingPath, strict: strict, tracker: tracker)
        }
    }

    struct Keyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
        let object: [String: JSONValue]
        let codingPath: [any CodingKey]
        let strict: Bool
        let tracker: Tracker
        let index: Int

        var allKeys: [Key] {
            tracker.touchAll(index)
            return object.keys.compactMap { Key(stringValue: $0) }
        }

        func contains(_ key: Key) -> Bool {
            tracker.touch(index, key.stringValue)
            return object[key.stringValue] != nil
        }

        private func child(_ key: Key) throws -> _Decoder {
            tracker.touch(index, key.stringValue)
            guard let v = object[key.stringValue] else {
                throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "missing \(key.stringValue)"))
            }
            return _Decoder(value: v, codingPath: codingPath + [key], strict: strict, tracker: tracker)
        }

        func decodeNil(forKey key: Key) throws -> Bool {
            tracker.touch(index, key.stringValue)
            guard let v = object[key.stringValue] else {
                throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "missing \(key.stringValue)"))
            }
            return v.isNull
        }

        func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
            try child(key).singleValueContainer().decode(T.self)
        }

        func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
            try child(key).container(keyedBy: type)
        }

        func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
            try child(key).unkeyedContainer()
        }

        func superDecoder() throws -> any Decoder {
            _Decoder(value: .object(object), codingPath: codingPath, strict: strict, tracker: tracker)
        }

        func superDecoder(forKey key: Key) throws -> any Decoder { try child(key) }
    }

    struct Unkeyed: UnkeyedDecodingContainer {
        let array: [JSONValue]
        let codingPath: [any CodingKey]
        let strict: Bool
        let tracker: Tracker
        var currentIndex = 0

        var count: Int? { array.count }
        var isAtEnd: Bool { currentIndex >= array.count }

        struct IndexKey: CodingKey {
            let intValue: Int?
            var stringValue: String { "\(intValue!)" }
            init(_ i: Int) { intValue = i }
            init?(stringValue: String) { intValue = Int(stringValue) }
            init?(intValue: Int) { self.intValue = intValue }
        }

        private mutating func next() throws -> _Decoder {
            guard !isAtEnd else {
                throw DecodingError.valueNotFound(JSONValue.self, .init(codingPath: codingPath, debugDescription: "array exhausted"))
            }
            let d = _Decoder(value: array[currentIndex], codingPath: codingPath + [IndexKey(currentIndex)], strict: strict, tracker: tracker)
            currentIndex += 1
            return d
        }

        mutating func decodeNil() throws -> Bool {
            guard !isAtEnd else { return false }
            if array[currentIndex].isNull { currentIndex += 1; return true }
            return false
        }

        mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
            try next().singleValueContainer().decode(T.self)
        }

        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
            try next().container(keyedBy: type)
        }

        mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
            try next().unkeyedContainer()
        }

        mutating func superDecoder() throws -> any Decoder { try next() }
    }

    struct Single: SingleValueDecodingContainer {
        let value: JSONValue
        let codingPath: [any CodingKey]
        let strict: Bool
        let tracker: Tracker

        func decodeNil() -> Bool { value.isNull }

        private func mismatch(_ type: Any.Type) -> DecodingError {
            .typeMismatch(type, .init(codingPath: codingPath, debugDescription: "expected \(type)"))
        }

        func decode(_ type: Bool.Type) throws -> Bool {
            guard case .bool(let b) = value else { throw mismatch(type) }
            return b
        }

        func decode(_ type: String.Type) throws -> String {
            guard case .string(let s) = value else { throw mismatch(type) }
            return s
        }

        func decode(_ type: Double.Type) throws -> Double {
            guard case .number(let n) = value else { throw mismatch(type) }
            return n
        }

        func decode(_ type: Float.Type) throws -> Float { Float(try decode(Double.self)) }

        private func integer<I: FixedWidthInteger>(_ type: I.Type) throws -> I {
            guard case .number(let n) = value else { throw mismatch(type) }
            guard n.rounded() == n, let i = I(exactly: n) else {
                throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "\(n) is not a \(type)"))
            }
            return i
        }

        func decode(_ type: Int.Type) throws -> Int { try integer(type) }
        func decode(_ type: Int8.Type) throws -> Int8 { try integer(type) }
        func decode(_ type: Int16.Type) throws -> Int16 { try integer(type) }
        func decode(_ type: Int32.Type) throws -> Int32 { try integer(type) }
        func decode(_ type: Int64.Type) throws -> Int64 { try integer(type) }
        func decode(_ type: UInt.Type) throws -> UInt { try integer(type) }
        func decode(_ type: UInt8.Type) throws -> UInt8 { try integer(type) }
        func decode(_ type: UInt16.Type) throws -> UInt16 { try integer(type) }
        func decode(_ type: UInt32.Type) throws -> UInt32 { try integer(type) }
        func decode(_ type: UInt64.Type) throws -> UInt64 { try integer(type) }

        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            if T.self == JSONValue.self { return value as! T }
            if T.self == Date.self {
                // Milliseconds since 1970, the same as the encoder everywhere else.
                return Date(timeIntervalSince1970: try decode(Double.self) / 1000) as! T
            }
            if T.self == URL.self {
                guard let u = URL(string: try decode(String.self)) else {
                    throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "not a URL"))
                }
                return u as! T
            }
            if T.self == Data.self {
                guard let d = Data(base64Encoded: try decode(String.self)) else {
                    throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "not base64"))
                }
                return d as! T
            }
            return try T(from: _Decoder(value: value, codingPath: codingPath, strict: strict, tracker: tracker))
        }
    }
}
