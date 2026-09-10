import Foundation

/// Where a handler runs. Main-actor handlers may touch the host, the store and
/// the session freely; detached handlers get only the request and should do
/// the slow thing they were detached for.
public enum RouteIsolation: Sendable {
    case main
    case detached
}

/// A route handler in either isolation.
public enum RouteHandler: Sendable {
    case main(@MainActor @Sendable (Request) async throws -> Response)
    case detached(@Sendable (Request) async throws -> Response)

    public func callAsFunction(_ request: Request) async throws -> Response {
        switch self {
        case .main(let h): return try await h(request)
        case .detached(let h): return try await h(request)
        }
    }
}

/// Matches paths to handlers. Patterns are `/literal/:param/*rest`; the most
/// specific match wins (literal over param over wildcard), first registered
/// breaking ties. `HEAD` falls back to a `GET` route.
public struct Router: Sendable {
    enum Segment: Sendable, Equatable {
        case literal(String)
        case param(String)
        case wildcard(String)
    }

    struct Entry: Sendable {
        let method: Request.Method?
        let pattern: String
        let segments: [Segment]
        let handler: RouteHandler
        let specificity: Int
    }

    public struct Match: Sendable {
        public let handler: RouteHandler
        public let params: [String: String]
        public let pattern: String
    }

    private(set) var entries: [Entry] = []

    public init() {}

    /// Adds a route. `method` nil matches every method.
    public mutating func add(_ method: Request.Method?, _ pattern: String, _ handler: RouteHandler) {
        let segments = Router.segments(of: pattern)
        let specificity = segments.reduce(0) { acc, s in
            switch s {
            case .literal: return acc + 3
            case .param: return acc + 2
            case .wildcard: return acc + 1
            }
        }
        entries.append(Entry(method: method, pattern: pattern, segments: segments, handler: handler, specificity: specificity))
    }

    public func match(_ method: Request.Method, _ path: String) -> Match? {
        let parts = Router.split(path)
        var best: (Entry, [String: String])?
        for entry in entries {
            guard entry.method == nil || entry.method == method || (method == .head && entry.method == .get) else { continue }
            guard let params = Router.bind(entry.segments, to: parts) else { continue }
            if let (b, _) = best, b.specificity >= entry.specificity { continue }
            best = (entry, params)
        }
        return best.map { Match(handler: $0.0.handler, params: $0.1, pattern: $0.0.pattern) }
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var patterns: [String] { entries.map(\.pattern) }

    static func split(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    static func segments(of pattern: String) -> [Segment] {
        split(pattern).map { part in
            if part.hasPrefix(":") { return .param(String(part.dropFirst())) }
            if part.hasPrefix("*") { return .wildcard(String(part.dropFirst())) }
            return .literal(part)
        }
    }

    static func bind(_ segments: [Segment], to parts: [String]) -> [String: String]? {
        var params: [String: String] = [:]
        var i = 0
        for (index, seg) in segments.enumerated() {
            switch seg {
            case .literal(let l):
                guard i < parts.count, parts[i] == l else { return nil }
                i += 1
            case .param(let name):
                guard i < parts.count else { return nil }
                params[name] = parts[i]
                i += 1
            case .wildcard(let name):
                // Only meaningful as the last segment; swallows the rest,
                // including nothing.
                guard index == segments.count - 1 else { return nil }
                params[name] = parts[i...].joined(separator: "/")
                return params
            }
        }
        return i == parts.count ? params : nil
    }
}

extension Sash {
    /// Whether a path or pattern is inside the framework's reserved prefix.
    public static func isReservedPath(_ path: String) -> Bool {
        path == "/_sash" || path.hasPrefix(reservedPathPrefix)
    }
}
