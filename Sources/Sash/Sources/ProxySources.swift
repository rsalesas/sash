import Foundation

/// Serves the web layer from an HTTP server on a unix socket: a daemon the
/// app is a companion to. Everything the page loads goes over the socket;
/// streams stay open until the page stops listening.
public final class SocketSource: Source, Sendable {
    public let path: String
    public let hostHeader: String
    private let client: HTTPClient

    public init(path: String, hostHeader: String = "localhost") {
        self.path = path
        self.hostHeader = hostHeader
        self.client = HTTPClient(endpoint: .unix(path: path), hostHeader: hostHeader)
    }

    public func respond(to request: Request) async -> Response? {
        await ProxySources.proxy(request, through: client, source: "socket \(path)")
    }
}

/// Serves the web layer from a TCP HTTP server on this machine or another:
/// a dev server, a staging build, a local backend on a port.
public final class RemoteSource: Source, Sendable {
    public let baseURL: URL
    private let client: HTTPClient
    let noStore: Bool

    /// - Parameter noStore: stamp `Cache-Control: no-store` on every
    ///   response, so an edited file is never served stale. For dev servers.
    public init(baseURL: URL, noStore: Bool = false) {
        precondition(baseURL.scheme == "http", "Sash: RemoteSource speaks plain HTTP to a local port; put TLS behind Net for anything else")
        self.baseURL = baseURL
        self.noStore = noStore
        let port = UInt16(baseURL.port ?? 80)
        self.client = HTTPClient(endpoint: .tcp(host: baseURL.host ?? "localhost", port: port),
                                 hostHeader: baseURL.port.map { "\(baseURL.host ?? "localhost"):\($0)" } ?? (baseURL.host ?? "localhost"))
    }

    public func respond(to request: Request) async -> Response? {
        var forwarded = request
        let prefix = baseURL.path.hasSuffix("/") ? String(baseURL.path.dropLast()) : baseURL.path
        if !prefix.isEmpty { forwarded.path = prefix + request.path }
        guard var response = await ProxySources.proxy(forwarded, through: client, source: baseURL.absoluteString) else { return nil }
        if noStore { response.headers["Cache-Control"] = "no-store" }
        return response
    }
}

enum ProxySources {
    /// Forwards a request and streams the answer back. A backend that cannot
    /// be reached is a 503 the page can show, not a 404 it would mistake for
    /// a missing file.
    static func proxy(_ request: Request, through client: HTTPClient, source: String) async -> Response? {
        do {
            let (head, body) = try await client.perform(request)
            let stream = AsyncStream<Data> { continuation in
                let task = Task {
                    do {
                        for try await chunk in body { continuation.yield(chunk) }
                    } catch {
                        Log.debug("proxy stream from \(source) ended: \(error)")
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            return Response(status: head.status, headers: head.headers.removingHopByHop(), body: .stream(stream))
        } catch {
            Log.warning("backend \(source) unreachable: \(error)")
            return .error(503, code: "backend-unavailable", message: "\(source): \(error)")
        }
    }
}

/// A directory that can be swapped while the app runs. Passes when it has no
/// root. The web-layer updater points it at each new version.
public final class OverlaySource: Source, Sendable {
    private let current = Locked<DirectorySource?>(nil)

    public init(root: URL? = nil) {
        if let root { current.withLock { $0 = DirectorySource(root: root) } }
    }

    public var root: URL? { current.value?.root }

    public func set(root: URL?) {
        current.withLock { $0 = root.map { DirectorySource(root: $0) } }
    }

    public func respond(to request: Request) async -> Response? {
        guard let source = current.value else { return nil }
        return await source.respond(to: request)
    }
}
