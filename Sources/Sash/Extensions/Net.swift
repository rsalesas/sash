import Foundation

/// Gives the page the network, proxied through `URLSession`, for the hosts
/// listed and no others. Also un-blocks those hosts in the page's own
/// `fetch`, `<img>` and friends; without this extension the page has no
/// network at all.
public struct Net: SashExtension {
    public static let namespace = "net"
    public static var requirements: [Requirement] { [.entitlement("com.apple.security.network.client")] }

    public let allowList: NetAllowList

    public init(allow: [String]) {
        self.allowList = NetAllowList(allow)
    }

    struct FetchArgs: Decodable, Sendable {
        var url: String
        var method: String?
        var headers: [String: String]?
        var body: String?
        /// "text" (default) or "base64".
        var bodyEncoding: String?
        var timeout: Double?
    }

    struct FetchResult: Encodable, Sendable {
        var status: Int
        var headers: [String: String]
        var body: String
        /// "text" or "base64".
        var encoding: String
        var url: String
    }

    public func register(in r: Registry) {
        let allow = allowList
        r.detachedCall("fetch") { (a: FetchArgs) in
            let request = try Net.makeRequest(a, allow: allow)
            let (data, response) = try await Net.session(allow: allow).data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CallError.failed("not an HTTP response") }
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields { headers[String(describing: k).lowercased()] = String(describing: v) }
            let text = Net.isTextual(http.mimeType) ? String(data: data, encoding: .utf8) : nil
            return FetchResult(status: http.statusCode, headers: headers,
                               body: text ?? data.base64EncodedString(), encoding: text == nil ? "base64" : "text",
                               url: http.url?.absoluteString ?? a.url)
        }
        // The same thing as a plain endpoint, with a streamed body, for pages
        // that want `Response.body` or `blob()`.
        r.reservedDetachedRoute(.post, "/_sash/net/fetch") { req in
            let a: FetchArgs = try req.json()
            let request = try Net.makeRequest(a, allow: allow)
            let (bytes, response) = try await Net.session(allow: allow).bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw CallError.failed("not an HTTP response") }
            var headers = Headers()
            for (k, v) in http.allHeaderFields {
                let name = String(describing: k)
                if name.lowercased() == "content-encoding" || name.lowercased() == "content-length" { continue }
                headers.add(name, String(describing: v))
            }
            let stream = AsyncStream<Data> { continuation in
                let task = Task {
                    var buffer = Data()
                    do {
                        for try await byte in bytes {
                            buffer.append(byte)
                            if buffer.count >= 16 * 1024 { continuation.yield(buffer); buffer = Data() }
                        }
                        if !buffer.isEmpty { continuation.yield(buffer) }
                    } catch {}
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            return Response(status: http.statusCode, headers: headers.removingHopByHop(), body: .stream(stream))
        }
    }

    nonisolated static func makeRequest(_ a: FetchArgs, allow: NetAllowList) throws -> URLRequest {
        guard let url = URL(string: a.url) else { throw CallError.invalidArgs("not a URL: \(a.url)") }
        guard allow.allows(url) else { throw CallError.denied("\(url.host ?? a.url) is not in the allow list") }
        var request = URLRequest(url: url, timeoutInterval: a.timeout ?? 30)
        request.httpMethod = (a.method ?? "GET").uppercased()
        for (k, v) in a.headers ?? [:] { request.setValue(v, forHTTPHeaderField: k) }
        if let body = a.body {
            if a.bodyEncoding == "base64" {
                guard let d = Data(base64Encoded: body) else { throw CallError.invalidArgs("body is not base64") }
                request.httpBody = d
            } else {
                request.httpBody = Data(body.utf8)
            }
        }
        return request
    }

    nonisolated static func isTextual(_ mime: String?) -> Bool {
        guard let m = mime?.lowercased() else { return false }
        return m.hasPrefix("text/") || m.contains("json") || m.contains("xml") || m.contains("javascript")
            || m.contains("x-www-form-urlencoded") || m == "application/graphql"
    }

    /// One session per allow list, whose delegate refuses redirects that
    /// leave the list.
    nonisolated static func session(allow: NetAllowList) -> URLSession {
        sessions.withLock { cache in
            if let s = cache[allow] { return s }
            let s = URLSession(configuration: .ephemeral, delegate: RedirectGuard(allow: allow), delegateQueue: nil)
            cache[allow] = s
            return s
        }
    }

    nonisolated private static let sessions = Locked<[NetAllowList: URLSession]>([:])

    final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        let allow: NetAllowList
        init(allow: NetAllowList) { self.allow = allow }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            if let url = request.url, allow.allows(url) { completionHandler(request) } else { completionHandler(nil) }
        }
    }
}
