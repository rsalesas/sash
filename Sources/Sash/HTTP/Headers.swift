import Foundation

/// An ordered, case-insensitive header collection.
public struct Headers: Sendable, Hashable, ExpressibleByDictionaryLiteral, Sequence {
    public private(set) var entries: [(name: String, value: String)] = []

    public init() {}
    public init(_ entries: [(String, String)]) { for (n, v) in entries { add(n, v) } }
    public init(dictionaryLiteral elements: (String, String)...) { for (n, v) in elements { add(n, v) } }
    public init(_ dictionary: [String: String]) { for (n, v) in dictionary.sorted(by: { $0.key < $1.key }) { add(n, v) } }

    /// The first value for `name`, or nil.
    public subscript(name: String) -> String? {
        get { entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }
        set {
            remove(name)
            if let newValue { add(name, newValue) }
        }
    }

    public func values(_ name: String) -> [String] {
        entries.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    public mutating func add(_ name: String, _ value: String) { entries.append((name, value)) }

    public mutating func remove(_ name: String) {
        entries.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func contains(_ name: String) -> Bool { self[name] != nil }

    /// A dictionary with the last value winning, for APIs that want one.
    public var dictionary: [String: String] {
        var d: [String: String] = [:]
        for (n, v) in entries { d[n] = v }
        return d
    }

    public func makeIterator() -> IndexingIterator<[(name: String, value: String)]> { entries.makeIterator() }

    public static func == (lhs: Headers, rhs: Headers) -> Bool {
        lhs.entries.map { "\($0.name.lowercased()):\($0.value)" } == rhs.entries.map { "\($0.name.lowercased()):\($0.value)" }
    }
    public func hash(into hasher: inout Hasher) {
        for (n, v) in entries { hasher.combine(n.lowercased()); hasher.combine(v) }
    }

    /// Hop-by-hop headers that describe one connection rather than the
    /// message. Never forwarded across a boundary; `Transfer-Encoding` in
    /// particular would claim a body that has already been de-chunked.
    public static let hopByHop: Set<String> = [
        "connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade", "proxy-connection",
    ]

    public func removingHopByHop() -> Headers {
        var h = Headers()
        for (n, v) in entries where !Headers.hopByHop.contains(n.lowercased()) { h.add(n, v) }
        return h
    }
}
