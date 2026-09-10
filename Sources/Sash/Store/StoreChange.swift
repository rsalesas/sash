import Foundation

/// Who made a change. Stamped on every write so a page can ignore its own echo
/// and the host can skip the originating session when fanning out.
public struct Origin: Sendable, Hashable, Codable {
    public var session: String?
    public var seq: UInt64

    public init(session: String?, seq: UInt64) {
        self.session = session
        self.seq = seq
    }
}

public struct StoreChange: Sendable, Hashable, Codable {
    public var scope: String
    public var key: String
    /// nil means removed.
    public var value: JSONValue?
    public var origin: Origin
}

/// One write from the page. A `null` or absent value removes the key.
public struct StoreOp: Sendable, Codable, Hashable {
    public var scope: String
    public var key: String
    public var value: JSONValue?

    public init(scope: String, key: String, value: JSONValue?) {
        self.scope = scope
        self.key = key
        self.value = value
    }

    enum CodingKeys: String, CodingKey { case scope, key, value }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scope = try c.decode(String.self, forKey: .scope)
        key = try c.decode(String.self, forKey: .key)
        let v = try c.decodeIfPresent(JSONValue.self, forKey: .value)
        value = (v?.isNull ?? true) ? nil : v
    }
}
