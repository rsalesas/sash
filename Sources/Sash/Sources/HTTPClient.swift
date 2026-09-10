import Foundation
import Network

/// A small HTTP/1.1 client over `NWConnection` for one peer at a time: a
/// unix socket or a TCP port on this machine. One connection per request
/// with `Connection: close`, which deletes the keep-alive state machine;
/// streams hold their connection until cancelled.
///
/// Hand-written rather than `URLSession` because `URLSession` cannot speak
/// to a unix socket, and rather than a full library because there is no TLS,
/// no HTTP/2, no redirects and no pooling to be had here.
final class HTTPClient: Sendable {
    enum Endpoint: Sendable, Hashable {
        case unix(path: String)
        case tcp(host: String, port: UInt16)

        var nwEndpoint: NWEndpoint {
            switch self {
            case .unix(let path): return .unix(path: path)
            case .tcp(let host, let port): return .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
            }
        }
    }

    struct Head: Sendable {
        var status: Int
        var reason: String
        var headers: Headers
    }

    enum ClientError: Error, CustomStringConvertible {
        case cannotConnect(String)
        case malformed(String)
        case cancelled

        var description: String {
            switch self {
            case .cannotConnect(let s): return "cannot connect: \(s)"
            case .malformed(let s): return "malformed response: \(s)"
            case .cancelled: return "cancelled"
            }
        }
    }

    let endpoint: Endpoint
    let hostHeader: String

    init(endpoint: Endpoint, hostHeader: String) {
        self.endpoint = endpoint
        self.hostHeader = hostHeader
    }

    /// Performs the request. The head arrives when the status line and
    /// headers have been parsed; the body streams after it. Cancelling the
    /// stream's consumer closes the connection.
    func perform(_ request: Request) async throws -> (Head, AsyncThrowingStream<Data, any Error>) {
        let task = Exchange(client: self, request: request)
        return try await task.run()
    }

    /// Buffers the whole response. Not for streams.
    func data(for request: Request) async throws -> (Head, Data) {
        let (head, stream) = try await perform(request)
        var out = Data()
        for try await chunk in stream { out.append(chunk) }
        return (head, out)
    }

    // MARK: One exchange

    private final class Exchange: @unchecked Sendable {
        enum Framing { case none, length(Int), chunked, untilClose }
        enum Phase { case head, body(Framing), chunkTrailer, done }

        let client: HTTPClient
        let request: Request
        let connection: NWConnection
        let queue = DispatchQueue(label: "sash.http")
        var buffer = Data()
        var phase = Phase.head
        var chunkRemaining = 0
        var headContinuation: CheckedContinuation<Head, any Error>?
        var bodyContinuation: AsyncThrowingStream<Data, any Error>.Continuation?
        var finished = false

        init(client: HTTPClient, request: Request) {
            self.client = client
            self.request = request
            self.connection = NWConnection(to: client.endpoint.nwEndpoint, using: .tcp)
        }

        func run() async throws -> (Head, AsyncThrowingStream<Data, any Error>) {
            let stream = AsyncThrowingStream<Data, any Error> { continuation in
                self.queue.async { self.bodyContinuation = continuation }
                continuation.onTermination = { [weak self] _ in self?.cancel() }
            }
            let head = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Head, any Error>) in
                queue.async {
                    self.headContinuation = c
                    self.start()
                }
            }
            return (head, stream)
        }

        private func start() {
            // Strong captures on purpose: the pending callbacks are what keep
            // this exchange alive after `perform` has returned the head and
            // the body is still arriving. Cleared when the connection ends.
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.send()
                    self.receive()
                case .waiting(let error):
                    // A missing socket file parks the connection in .waiting
                    // and retries forever. Fail fast instead; the caller owns
                    // retry policy.
                    self.fail(ClientError.cannotConnect(error.localizedDescription))
                case .failed(let error):
                    self.fail(ClientError.cannotConnect(error.localizedDescription))
                case .cancelled:
                    self.endOfStream()
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        private func send() {
            var pathAndQuery = request.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? request.path
            if let q = request.rawQuery, !q.isEmpty { pathAndQuery += "?" + q }
            var text = "\(request.method.rawValue) \(pathAndQuery) HTTP/1.1\r\n"
            text += "Host: \(client.hostHeader)\r\nConnection: close\r\nAccept-Encoding: identity\r\n"
            // Origin is dropped: WebKit stamps the private scheme on it and a
            // backend's CSRF guard would rightly reject that.
            let skip: Set<String> = ["host", "connection", "accept-encoding", "origin", "content-length", "transfer-encoding"]
            for (n, v) in request.headers where !skip.contains(n.lowercased()) { text += "\(n): \(v)\r\n" }
            if let body = request.body { text += "Content-Length: \(body.count)\r\n" }
            text += "\r\n"
            var data = Data(text.utf8)
            if let body = request.body { data.append(body) }
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { self.fail(ClientError.cannotConnect(error.localizedDescription)) }
            })
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.drain()
                }
                if let error { self.fail(ClientError.cannotConnect(error.localizedDescription)); return }
                if isComplete { self.endOfStream(); return }
                if case .done = self.phase { return }
                self.receive()
            }
        }

        /// Consumes as much of the buffer as the current phase allows. Loops
        /// because one read can carry the head, several chunks and the end.
        private func drain() {
            while true {
                switch phase {
                case .head:
                    guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
                    // Data slices keep their indices; never assume 0 is the start.
                    let headData = Data(buffer[buffer.startIndex..<range.lowerBound])
                    buffer = Data(buffer[range.upperBound...])
                    guard let head = Exchange.parseHead(headData) else {
                        fail(ClientError.malformed("bad status line")); return
                    }
                    let framing = Exchange.framing(for: head, method: request.method)
                    phase = .body(framing)
                    headContinuation?.resume(returning: head)
                    headContinuation = nil
                    if case .none = framing { finish(); return }
                case .body(.length(let remaining)):
                    if buffer.isEmpty { return }
                    let take = min(remaining, buffer.count)
                    yield(buffer.prefix(take))
                    buffer = Data(buffer.dropFirst(take))
                    if take == remaining { finish(); return }
                    phase = .body(.length(remaining - take))
                case .body(.untilClose):
                    if buffer.isEmpty { return }
                    yield(buffer)
                    buffer.removeAll()
                case .body(.chunked):
                    if chunkRemaining == 0 {
                        guard let line = takeLine() else { return }
                        let sizeText = line.split(separator: ";").first.map(String.init) ?? ""
                        guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else {
                            fail(ClientError.malformed("bad chunk size")); return
                        }
                        if size == 0 { phase = .chunkTrailer; continue }
                        chunkRemaining = size
                    }
                    if buffer.isEmpty { return }
                    let take = min(chunkRemaining, buffer.count)
                    yield(buffer.prefix(take))
                    buffer = Data(buffer.dropFirst(take))
                    chunkRemaining -= take
                    if chunkRemaining == 0 {
                        // The CRLF after the chunk data.
                        guard buffer.count >= 2 else { chunkRemaining = -1; return }
                        buffer = Data(buffer.dropFirst(2))
                    }
                    if chunkRemaining == -1 {
                        guard buffer.count >= 2 else { return }
                        buffer = Data(buffer.dropFirst(2))
                        chunkRemaining = 0
                    }
                case .chunkTrailer:
                    guard let line = takeLine() else { return }
                    if line.isEmpty { finish(); return }
                case .body(.none), .done:
                    return
                }
            }
        }

        private func takeLine() -> String? {
            guard let range = buffer.range(of: Data("\r\n".utf8)) else { return nil }
            let line = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
            buffer = Data(buffer[range.upperBound...])
            return line
        }

        private func yield(_ data: Data) {
            guard !finished, !data.isEmpty else { return }
            bodyContinuation?.yield(Data(data))
        }

        private func endOfStream() {
            switch phase {
            case .head:
                fail(ClientError.malformed("connection closed before the head"))
            case .body(.length(let remaining)) where remaining > 0:
                fail(ClientError.malformed("connection closed \(remaining) bytes early"))
            case .done:
                break
            default:
                finish()
            }
        }

        private func finish() {
            guard !finished else { return }
            finished = true
            phase = .done
            bodyContinuation?.finish()
            bodyContinuation = nil
            closeConnection()
        }

        private func closeConnection() {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }

        private func fail(_ error: any Error) {
            guard !finished else { return }
            finished = true
            phase = .done
            headContinuation?.resume(throwing: error)
            headContinuation = nil
            bodyContinuation?.finish(throwing: error)
            bodyContinuation = nil
            closeConnection()
        }

        func cancel() {
            queue.async {
                guard !self.finished else { return }
                self.finished = true
                self.phase = .done
                self.headContinuation?.resume(throwing: ClientError.cancelled)
                self.headContinuation = nil
                self.bodyContinuation?.finish()
                self.bodyContinuation = nil
                self.closeConnection()
            }
        }

        static func parseHead(_ data: Data) -> Head? {
            let text = String(decoding: data, as: UTF8.self)
            var lines = text.components(separatedBy: "\r\n")
            guard let statusLine = lines.first else { return nil }
            lines.removeFirst()
            let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else { return nil }
            var headers = Headers()
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers.add(String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                            String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            }
            return Head(status: status, reason: parts.count > 2 ? String(parts[2]) : "", headers: headers)
        }

        static func framing(for head: Head, method: Request.Method) -> Framing {
            if method == .head || head.status == 204 || head.status == 304 || (100..<200).contains(head.status) { return .none }
            if head.headers["Transfer-Encoding"]?.lowercased().contains("chunked") == true { return .chunked }
            if let l = head.headers["Content-Length"].flatMap(Int.init) { return l == 0 ? .none : .length(l) }
            return .untilClose
        }
    }
}
