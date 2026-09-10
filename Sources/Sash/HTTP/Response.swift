import Foundation

/// What a route handler or a source answers with.
public struct Response: Sendable {
    public enum Body: Sendable {
        case empty
        case data(Data)
        /// Delivered to the page chunk by chunk as it arrives. This is what
        /// makes Server-Sent Events work.
        case stream(AsyncStream<Data>)
    }

    public var status: Int
    public var headers: Headers
    public var body: Body

    public init(status: Int = 200, headers: Headers = [:], body: Body = .empty) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static let ok = Response(status: 200)
    public static let noContent = Response(status: 204)
    public static let notFound = Response.error(404, code: "not-found", message: "Not found")

    public static func status(_ status: Int) -> Response { Response(status: status) }

    public static func data(_ data: Data, contentType: String, status: Int = 200, headers: Headers = [:]) -> Response {
        var h = headers
        h["Content-Type"] = contentType
        h["Content-Length"] = String(data.count)
        return Response(status: status, headers: h, body: .data(data))
    }

    public static func text(_ text: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") -> Response {
        .data(Data(text.utf8), contentType: contentType, status: status)
    }

    public static func html(_ html: String, status: Int = 200) -> Response {
        .text(html, status: status, contentType: "text/html; charset=utf-8")
    }

    public static func json(_ value: JSONValue, status: Int = 200) -> Response {
        .data((try? value.serialized()) ?? Data("null".utf8), contentType: "application/json; charset=utf-8", status: status)
    }

    public static func json<T: Encodable>(_ value: T, status: Int = 200) throws -> Response {
        .data(try JSONEncoder.sash.encode(value), contentType: "application/json; charset=utf-8", status: status)
    }

    /// A JSON error body in the same shape the call bridge uses:
    /// `{ "error": { "code": ..., "message": ... } }`.
    public static func error(_ status: Int, code: String, message: String) -> Response {
        .json(["error": ["code": .string(code), "message": .string(message)]], status: status)
    }

    /// A streamed body. `produce` receives the continuation and returns at
    /// once; whoever holds the continuation feeds the stream.
    public static func stream(contentType: String, status: Int = 200, headers: Headers = [:],
                              bufferingPolicy: AsyncStream<Data>.Continuation.BufferingPolicy = .unbounded,
                              _ produce: (AsyncStream<Data>.Continuation) -> Void) -> Response {
        var h = headers
        h["Content-Type"] = contentType
        let stream = AsyncStream<Data>(bufferingPolicy: bufferingPolicy) { produce($0) }
        return Response(status: status, headers: h, body: .stream(stream))
    }

    /// Collects the whole body. For tests and for callers that know the body
    /// is finite.
    public func collectedBody() async -> Data {
        switch body {
        case .empty: return Data()
        case .data(let d): return d
        case .stream(let s):
            var out = Data()
            for await chunk in s { out.append(chunk) }
            return out
        }
    }
}
