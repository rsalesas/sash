import Foundation

/// When an injected script runs.
public enum ScriptInjection: Sendable {
    case documentStart
    case documentEnd
}

/// A native command an extension makes available to menus and toolbars. The
/// page claims it in context; the app renders it however it likes.
public struct Command: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var key: String?

    public init(id: String, title: String, key: String? = nil) {
        self.id = id
        self.title = title
        self.key = key
    }
}

/// Where extensions declare what the page may reach. Every declaration is
/// namespaced by the extension being registered; the host sets the namespace
/// around each `register(in:)` call.
@MainActor
public final class Registry {
    struct AnyCall: Sendable {
        let namespace: String
        let name: String
        let invoke: @MainActor @Sendable (JSONValue, Session) async throws -> JSONValue
    }

    struct Script: Sendable {
        let namespace: String
        let source: String
        let injection: ScriptInjection
    }

    private(set) var router = Router()
    private(set) var calls: [String: [String: AnyCall]] = [:]
    private(set) var scripts: [Script] = []
    private(set) var events: [String: [String]] = [:]
    private(set) var commands: [Command] = []
    private(set) var routePatterns: [String: [String]] = [:]

    /// The namespace declarations are filed under. nil outside registration.
    var currentNamespace: String?
    /// Only the host may register under the reserved prefix.
    var allowsReservedRoutes = false

    init() {}

    private var namespace: String {
        guard let ns = currentNamespace else {
            preconditionFailure("Sash: registry used outside of an extension's register(in:)")
        }
        return ns
    }

    // MARK: Calls

    /// A call taking arguments and the session that made it.
    public func call<A: Decodable & Sendable, R: Encodable & Sendable>(
        _ name: String,
        _ handler: @escaping @MainActor @Sendable (A, Session) async throws -> R
    ) {
        register(name) { args, session in
            let a: A = try Registry.decode(args)
            return try Registry.encode(try await handler(a, session))
        }
    }

    /// A call taking arguments only.
    public func call<A: Decodable & Sendable, R: Encodable & Sendable>(
        _ name: String,
        _ handler: @escaping @MainActor @Sendable (A) async throws -> R
    ) {
        call(name) { (a: A, _: Session) in try await handler(a) }
    }

    /// A call with no arguments.
    public func call<R: Encodable & Sendable>(
        _ name: String,
        _ handler: @escaping @MainActor @Sendable (Session) async throws -> R
    ) {
        register(name) { _, session in try Registry.encode(try await handler(session)) }
    }

    public func call<R: Encodable & Sendable>(
        _ name: String,
        _ handler: @escaping @MainActor @Sendable () async throws -> R
    ) {
        register(name) { _, _ in try Registry.encode(try await handler()) }
    }

    /// A call that returns nothing.
    public func call<A: Decodable & Sendable>(
        _ name: String,
        _ handler: @escaping @MainActor @Sendable (A, Session) async throws -> Void
    ) {
        register(name) { args, session in
            let a: A = try Registry.decode(args)
            try await handler(a, session)
            return .null
        }
    }

    public func call<A: Decodable & Sendable>(
        _ name: String,
        _ handler: @escaping @MainActor @Sendable (A) async throws -> Void
    ) {
        call(name) { (a: A, _: Session) in try await handler(a) }
    }

    public func call(_ name: String, _ handler: @escaping @MainActor @Sendable (Session) async throws -> Void) {
        register(name) { _, session in try await handler(session); return .null }
    }

    public func call(_ name: String, _ handler: @escaping @MainActor @Sendable () async throws -> Void) {
        register(name) { _, _ in try await handler(); return .null }
    }

    /// A call whose work runs off the main actor. It receives only its
    /// arguments; anything it needs from the session it must be given.
    public func detachedCall<A: Decodable & Sendable, R: Encodable & Sendable>(
        _ name: String,
        _ handler: @escaping @Sendable (A) async throws -> R
    ) {
        register(name) { args, _ in
            let a: A = try Registry.decode(args)
            let r = try await Task.detached { try await handler(a) }.value
            return try Registry.encode(r)
        }
    }

    private func register(_ name: String, _ invoke: @escaping @MainActor @Sendable (JSONValue, Session) async throws -> JSONValue) {
        let ns = namespace
        precondition(calls[ns]?[name] == nil, "Sash: call \(ns).\(name) registered twice")
        calls[ns, default: [:]][name] = AnyCall(namespace: ns, name: name, invoke: invoke)
    }

    // MARK: Routes

    public func route(_ method: Request.Method?, _ pattern: String, isolation: RouteIsolation = .main,
                      _ handler: @escaping @MainActor @Sendable (Request) async throws -> Response) {
        addRoute(method, pattern, .main(handler))
    }

    public func detachedRoute(_ method: Request.Method?, _ pattern: String,
                              _ handler: @escaping @Sendable (Request) async throws -> Response) {
        addRoute(method, pattern, .detached(handler))
    }

    /// A Server-Sent Events route. The body runs for as long as the page
    /// listens and is cancelled when it stops.
    public func stream(_ pattern: String,
                       _ body: @escaping @MainActor @Sendable (SSEEmitter, Request) async -> Void) {
        addRoute(.get, pattern, .main({ request in
            SSE.response { emitter in await body(emitter, request) }
        }))
    }

    private func addRoute(_ method: Request.Method?, _ pattern: String, _ handler: RouteHandler) {
        let ns = namespace
        precondition(pattern.hasPrefix("/"), "Sash: route pattern must start with /: \(pattern)")
        precondition(allowsReservedRoutes || !Sash.isReservedPath(pattern),
                     "Sash: \(ns) tried to register \(pattern); \(Sash.reservedPathPrefix) is reserved")
        router.add(method, pattern, handler)
        routePatterns[ns, default: []].append(pattern)
    }

    // MARK: Scripts, events, commands

    /// JavaScript to run in every page, before or after the document. For
    /// polyfills and shims. Main frame only.
    public func script(_ source: String, at injection: ScriptInjection = .documentStart) {
        scripts.append(Script(namespace: namespace, source: source, injection: injection))
    }

    /// Declares an event the extension emits, so the page can see it in
    /// capabilities.
    public func event(_ name: String) {
        events[namespace, default: []].append(name)
    }

    /// Declares a native command the page may claim in its context.
    public func command(_ id: String, title: String, key: String? = nil) {
        commands.append(Command(id: id, title: title, key: key))
    }

    // MARK: Dispatch

    func dispatch(namespace ns: String, name: String, args: JSONValue, session: Session) async -> JSONValue {
        guard let call = calls[ns]?[name] else {
            return CallError.capabilityMissing(calls[ns] == nil ? ns : "\(ns).\(name)").envelope
        }
        do {
            return successEnvelope(try await call.invoke(args, session))
        } catch {
            return CallError.wrap(error).envelope
        }
    }

    var capabilities: Capabilities {
        var caps = Capabilities()
        let names = Set(calls.keys).union(events.keys).union(routePatterns.keys)
        for ns in names {
            caps.namespaces[ns] = .init(
                calls: (calls[ns]?.keys.sorted()) ?? [],
                events: events[ns] ?? [],
                routes: routePatterns[ns] ?? []
            )
        }
        return caps
    }

    // MARK: Coding

    static func decode<A: Decodable>(_ args: JSONValue) throws -> A {
        if A.self == JSONValue.self { return args as! A }
        do {
            return try args.decode(A.self)
        } catch let e as DecodingError {
            throw CallError.invalidArgs(e.sashDescription)
        }
    }

    static func encode<R: Encodable>(_ value: R) throws -> JSONValue {
        if let j = value as? JSONValue { return j }
        return try JSONValue(encoding: value)
    }
}

/// Arguments for a call that takes none. The page may still send `{}`.
public struct NoArgs: Decodable, Sendable {
    public init() {}
    public init(from decoder: any Decoder) throws {}
}
