import Foundation

/// Where a session starts: a path and query inside the page. Also the page's
/// `location.pathname`, so an SPA router needs nothing special.
public struct Route: Sendable, Hashable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var path: String
    public var query: [String: String]

    public init(_ path: String = "/", query: [String: String] = [:]) {
        self.path = path.hasPrefix("/") ? path : "/" + path
        self.query = query
    }

    public init(stringLiteral value: String) {
        if let q = value.firstIndex(of: "?") {
            self.init(String(value[..<q]), query: Request.parseQuery(String(value[value.index(after: q)...])))
        } else {
            self.init(value)
        }
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = Sash.scheme
        c.host = Sash.authority
        c.path = path
        if !query.isEmpty {
            c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return c.url!
    }

    public var description: String { url.absoluteString }
}
