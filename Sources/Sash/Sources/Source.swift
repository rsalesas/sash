import Foundation

/// Answers requests for the web layer's files. Returns nil to pass the request
/// to the next source in the chain.
public protocol Source: Sendable {
    func respond(to request: Request) async -> Response?
}

/// Where the web layer comes from.
public indirect enum WebLayer: Sendable {
    /// A directory on disk, served as-is.
    case directory(URL)
    /// An HTTP server on a unix socket, for companions to a local daemon.
    case socket(path: String, hostHeader: String = "localhost")
    /// A plain-HTTP server on a port, such as a local backend.
    case remote(URL)
    /// A dev server such as Vite. Nothing is cached, and the server's host
    /// is added to the network allow list so live reload can connect.
    case dev(URL)
    /// Layers consulted in order; the first to answer wins.
    case layered([WebLayer])
    /// An explicit chain, consulted in order.
    case sources([any Source])

    /// Files inside a bundle, optionally under a subdirectory. Resolved
    /// eagerly so a missing folder fails at configuration time, not on the
    /// first request.
    public static func bundle(_ bundle: Bundle, subdirectory: String? = nil) -> WebLayer {
        guard let resources = bundle.resourceURL else {
            preconditionFailure("Sash: bundle \(bundle.bundlePath) has no resources directory")
        }
        let root = subdirectory.map { resources.appendingPathComponent($0, isDirectory: true) } ?? resources
        precondition(FileManager.default.fileExists(atPath: root.path),
                     "Sash: web layer directory does not exist: \(root.path)")
        return .directory(root)
    }

    public var sources: [any Source] {
        switch self {
        case .directory(let url): return [DirectorySource(root: url)]
        case .socket(let path, let hostHeader): return [SocketSource(path: path, hostHeader: hostHeader)]
        case .remote(let url): return [RemoteSource(baseURL: url)]
        case .dev(let url): return [RemoteSource(baseURL: url, noStore: true)]
        case .layered(let layers): return layers.flatMap(\.sources)
        case .sources(let s): return s
        }
    }

    /// Hosts the page must be allowed to reach for this layer to work: the
    /// dev server, so its live-reload socket connects.
    public var requiredNetworkHosts: [String] {
        switch self {
        case .dev(let url): return [url.host ?? "localhost"]
        case .layered(let layers): return layers.flatMap(\.requiredNetworkHosts)
        default: return []
        }
    }

    /// The directory this layer serves from disk, when it is one.
    var directory: URL? {
        switch self {
        case .directory(let url): return url
        case .layered(let layers): return layers.lazy.compactMap(\.directory).first
        default: return nil
        }
    }
}
