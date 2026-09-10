import Foundation

/// Server-Sent Events framing and a streaming response builder.
public enum SSE {
    public static let contentType = "text/event-stream; charset=utf-8"

    /// One frame. Multi-line data becomes multiple `data:` lines, as the
    /// protocol requires; a lone `\r` is normalised so it cannot split a line.
    public static func frame(event: String? = nil, data: String, id: String? = nil, retry: Int? = nil) -> Data {
        var out = ""
        if let id { out += "id: \(id.sanitizedForSSEField)\n" }
        if let event { out += "event: \(event.sanitizedForSSEField)\n" }
        if let retry { out += "retry: \(retry)\n" }
        for line in data.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            out += "data: \(line.replacingOccurrences(of: "\r", with: ""))\n"
        }
        out += "\n"
        return Data(out.utf8)
    }

    public static func comment(_ text: String) -> Data {
        Data(": \(text.sanitizedForSSEField)\n\n".utf8)
    }

    /// The headers every SSE response carries. No `Connection`: this is not a
    /// connection.
    public static var headers: Headers {
        ["Content-Type": contentType, "Cache-Control": "no-cache", "X-Accel-Buffering": "no"]
    }

    /// A streaming response whose body is produced by `body` running in its
    /// own task. The task is cancelled when the page stops listening, and the
    /// stream ends when `body` returns or calls `emitter.finish()`.
    ///
    /// The stream opens with a `:ok` comment so the page's `EventSource`
    /// fires `onopen` immediately rather than on the first real event.
    public static func response(status: Int = 200, headers extra: Headers = [:],
                                _ body: @escaping @Sendable (SSEEmitter) async -> Void) -> Response {
        var h = headers
        for (n, v) in extra { h[n] = v }
        let stream = AsyncStream<Data>(bufferingPolicy: .unbounded) { continuation in
            let emitter = SSEEmitter(continuation)
            continuation.yield(SSE.comment("ok"))
            let task = Task {
                await body(emitter)
                emitter.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                emitter.markFinished()
            }
        }
        return Response(status: status, headers: h, body: .stream(stream))
    }
}

/// Writes frames into an SSE response. Safe to use from any task; sends after
/// `finish()` are dropped.
public final class SSEEmitter: Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private let state = Locked(false)

    init(_ continuation: AsyncStream<Data>.Continuation) { self.continuation = continuation }

    public var isFinished: Bool { state.value }

    public func send(_ event: String? = nil, data: String, id: String? = nil) {
        guard !isFinished else { return }
        continuation.yield(SSE.frame(event: event, data: data, id: id))
    }

    public func send<T: Encodable>(_ event: String, json value: T, id: String? = nil) throws {
        let data = try JSONEncoder.sash.encode(value)
        send(event, data: String(decoding: data, as: UTF8.self), id: id)
    }

    public func send(_ event: String, _ value: JSONValue, id: String? = nil) {
        send(event, data: (try? String(decoding: value.serialized(), as: UTF8.self)) ?? "null", id: id)
    }

    public func comment(_ text: String) {
        guard !isFinished else { return }
        continuation.yield(SSE.comment(text))
    }

    /// Sends raw, pre-framed bytes.
    public func raw(_ data: Data) {
        guard !isFinished else { return }
        continuation.yield(data)
    }

    public func finish() {
        guard !state.exchange(true) else { return }
        continuation.finish()
    }

    func markFinished() { _ = state.exchange(true) }
}

extension String {
    var sanitizedForSSEField: String {
        replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ")
    }
}

/// A tiny lock-protected box for the few places that are not on the main actor.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try body(&stored)
    }

    func exchange(_ newValue: Value) -> Value {
        lock.lock(); defer { lock.unlock() }
        let old = stored
        stored = newValue
        return old
    }
}
