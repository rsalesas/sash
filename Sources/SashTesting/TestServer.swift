import Foundation
import Network
import Sash

/// A tiny HTTP/1.1 server for tests: one request per connection, answered by
/// a Sash `Response`, with streamed bodies sent chunked. Listens on a unix
/// socket or a TCP port so the socket and remote sources can be exercised
/// against something real.
public final class TestServer: @unchecked Sendable {
    public typealias Handler = @Sendable (Request) async -> Response

    private let handler: Handler
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "sash.testserver")
    private var connections: [ObjectIdentifier: Conn] = [:]
    public private(set) var requestCount = 0

    public init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    public func start(unixPath: String) throws {
        try? FileManager.default.removeItem(atPath: unixPath)
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .unix(path: unixPath)
        try start(params)
    }

    /// Listens on an ephemeral TCP port and returns it.
    @discardableResult
    public func start(tcp: Void = ()) throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        try start(params)
        let sem = DispatchSemaphore(value: 0)
        var port: UInt16 = 0
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let p = listener?.port?.rawValue, p != 0 { port = p; break }
            _ = sem.wait(timeout: .now() + 0.02)
        }
        return port
    }

    private func start(_ params: NWParameters) throws {
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        listener = l
    }

    public func stop() {
        listener?.cancel()
        queue.sync { connections.values.forEach { $0.connection.cancel() }; connections.removeAll() }
    }

    private func accept(_ connection: NWConnection) {
        let conn = Conn(connection: connection, server: self)
        connections[ObjectIdentifier(conn)] = conn
        conn.start(on: queue)
    }

    fileprivate func finished(_ conn: Conn) {
        queue.async { self.connections.removeValue(forKey: ObjectIdentifier(conn)) }
    }

    fileprivate func handle(_ request: Request) async -> Response {
        queue.sync { requestCount += 1 }
        return await handler(request)
    }

    fileprivate final class Conn: @unchecked Sendable {
        let connection: NWConnection
        unowned let server: TestServer
        var buffer = Data()
        var queue: DispatchQueue!

        init(connection: NWConnection, server: TestServer) {
            self.connection = connection
            self.server = server
        }

        func start(on queue: DispatchQueue) {
            self.queue = queue
            connection.start(queue: queue)
            receive()
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, complete, error in
                if let data { buffer.append(data) }
                if tryParse() { return }
                if error != nil || complete { connection.cancel(); server.finished(self); return }
                receive()
            }
        }

        /// Returns true once a full request has been parsed and dispatched.
        private func tryParse() -> Bool {
            guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return false }
            let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
            var lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst().split(separator: " ")
            guard requestLine.count >= 2 else { connection.cancel(); return true }
            var headers = Headers()
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers.add(String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                            String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            }
            let length = headers["Content-Length"].flatMap(Int.init) ?? 0
            let bodyStart = range.upperBound
            guard buffer.count - bodyStart >= length else { return false }
            let body = length > 0 ? Data(buffer[bodyStart..<(bodyStart + length)]) : nil
            let target = String(requestLine[1])
            let url = URL(string: "http://test" + target) ?? URL(string: "http://test/")!
            let request = Request(method: Request.Method(String(requestLine[0])) ?? .get, url: url, headers: headers, body: body)
            Task { await self.respond(with: await self.server.handle(request), head: request.method == .head) }
            return true
        }

        private func respond(with response: Response, head headOnly: Bool) async {
            var text = "HTTP/1.1 \(response.status) \(HTTPURLResponse.localizedString(forStatusCode: response.status))\r\n"
            var headers = response.headers
            switch response.body {
            case .empty: headers["Content-Length"] = "0"
            case .data(let d): headers["Content-Length"] = String(d.count)
            case .stream: headers["Transfer-Encoding"] = "chunked"; headers.remove("Content-Length")
            }
            headers["Connection"] = "close"
            for (n, v) in headers { text += "\(n): \(v)\r\n" }
            text += "\r\n"
            await send(Data(text.utf8))
            if headOnly { close(); return }
            switch response.body {
            case .empty: break
            case .data(let d): await send(d)
            case .stream(let s):
                for await chunk in s {
                    guard !chunk.isEmpty else { continue }
                    var frame = Data("\(String(chunk.count, radix: 16))\r\n".utf8)
                    frame.append(chunk)
                    frame.append(Data("\r\n".utf8))
                    await send(frame)
                    if connection.state != .ready { break }
                }
                await send(Data("0\r\n\r\n".utf8))
            }
            close()
        }

        private func send(_ data: Data) async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                connection.send(content: data, completion: .contentProcessed { _ in c.resume() })
            }
        }

        private func close() {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] _ in
                connection.cancel()
                server.finished(self)
            })
        }
    }
}
