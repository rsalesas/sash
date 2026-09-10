import Foundation

/// Answers requests for the web layer's files. Returns nil to pass the request
/// to the next source in the chain.
public protocol Source: Sendable {
    func respond(to request: Request) async -> Response?
}

/// Where the web layer comes from.
public enum WebLayer: Sendable {
    /// A directory on disk, served as-is.
    case directory(URL)
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
        case .sources(let s): return s
        }
    }
}
