import Foundation

/// A request the page made, as seen by a route handler.
public struct Request: Sendable {
    public enum Method: String, Sendable, Hashable, CaseIterable {
        case get = "GET", head = "HEAD", post = "POST", put = "PUT", patch = "PATCH"
        case delete = "DELETE", options = "OPTIONS"

        public init?(_ raw: String) { self.init(rawValue: raw.uppercased()) }
    }

    public var method: Method
    /// The path, percent-decoded, without the query.
    public var path: String
    /// The query string as sent, without the `?`.
    public var rawQuery: String?
    /// Decoded query parameters; the last duplicate wins.
    public var query: [String: String]
    public var headers: Headers
    /// Path parameters filled in by the router (`/api/:id` → `["id": ...]`).
    public var params: [String: String] = [:]
    /// The body, complete. WebKit hands the whole body over at start, so a
    /// streaming request body would be theatre.
    public var body: Data?
    /// The session that made the request, when it came from a page.
    public var session: Session?

    public init(method: Method = .get, path: String, rawQuery: String? = nil,
                headers: Headers = [:], body: Data? = nil, session: Session? = nil) {
        self.method = method
        self.path = path
        self.rawQuery = rawQuery
        self.query = Request.parseQuery(rawQuery)
        self.headers = headers
        self.body = body
        self.session = session
    }

    /// Builds a request from a URL's path and query.
    public init(method: Method = .get, url: URL, headers: Headers = [:], body: Data? = nil, session: Session? = nil) {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = comps?.path.isEmpty == false ? comps!.path : "/"
        self.init(method: method, path: path, rawQuery: comps?.percentEncodedQuery,
                  headers: headers, body: body, session: session)
    }

    /// Decodes the body as JSON.
    public func json<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        guard let body, !body.isEmpty else {
            throw DecodingError.valueNotFound(T.self, .init(codingPath: [], debugDescription: "Empty request body"))
        }
        return try JSONDecoder.sash.decode(T.self, from: body)
    }

    public var bodyText: String? { body.flatMap { String(data: $0, encoding: .utf8) } }

    static func parseQuery(_ raw: String?) -> [String: String] {
        guard let raw, !raw.isEmpty else { return [:] }
        var out: [String: String] = [:]
        for pair in raw.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let k = String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(parts[0])
            let v = parts.count > 1 ? (String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(parts[1])) : ""
            out[k] = v
        }
        return out
    }
}
