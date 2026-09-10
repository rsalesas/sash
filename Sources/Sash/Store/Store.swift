import Foundation
import Observation

/// The shared state. Named scopes of JSON values, each with its own
/// persistence and visibility. Backs `sash.state`, the `localStorage` shim,
/// and the Settings window.
@MainActor
@Observable
public final class Store {
    public let configuration: StoreConfiguration
    /// Increments on every write. The page compares it against the one in its
    /// boot snapshot to know whether it missed anything.
    public private(set) var seq: UInt64 = 0

    @ObservationIgnored private var scopes: [String: Scope] = [:]
    @ObservationIgnored private var warnedUndeclared: Set<String> = []
    /// The host installs this to fan changes out to sessions.
    @ObservationIgnored var onChange: ((StoreChange) -> Void)?

    public init(configuration: StoreConfiguration = .default) {
        self.configuration = configuration
        for c in configuration.scopes { declare(c) }
    }

    /// Declares (or re-declares) a scope. Values are loaded from persistence
    /// at declaration.
    public func declare(_ config: ScopeConfiguration) {
        let backend: any StoreBackend
        switch config.persistence {
        case .memory: backend = MemoryBackend()
        case .userDefaults(let suite): backend = UserDefaultsBackend(suite: suite, prefix: configuration.defaultsKeyPrefix)
        case .file(let directory): backend = FileBackend(directory: directory)
        case .ubiquitous:
            let u = UbiquitousBackend(prefix: configuration.defaultsKeyPrefix)
            backend = u
            watchUbiquitousChanges(u)
        }
        let scope = Scope(name: config.name, configuration: config, backend: backend, store: self)
        scopes[config.name] = scope
    }

    /// The scope by name. An undeclared name gets an in-memory, Swift-only
    /// scope and one log line, so a typo is visible but not fatal.
    public func scope(_ name: String) -> Scope {
        if let s = scopes[name] { return s }
        if !warnedUndeclared.contains(name) {
            warnedUndeclared.insert(name)
            Log.warning("store scope \"\(name)\" was not declared; using memory, Swift-only")
        }
        declare(ScopeConfiguration(name))
        return scopes[name]!
    }

    public var allScopes: [Scope] { scopes.values.sorted { $0.name < $1.name } }
    public var visibleScopes: [Scope] { allScopes.filter { $0.configuration.visibility == .page } }

    public func isVisible(_ name: String) -> Bool { scopes[name]?.configuration.visibility == .page }

    /// Every value the page may see, for the boot snapshot.
    public func snapshot(visibleOnly: Bool = true) -> [String: [String: JSONValue]] {
        var out: [String: [String: JSONValue]] = [:]
        for s in visibleOnly ? visibleScopes : allScopes { out[s.name] = s.values }
        return out
    }

    /// Applies writes from a page. Writes to scopes the page cannot see are
    /// dropped and logged; a page is not trusted to name a scope.
    public func apply(_ ops: [StoreOp], from sessionID: String?) {
        for op in ops {
            guard let scope = scopes[op.scope], scope.configuration.visibility == .page else {
                Log.warning("page write to scope \"\(op.scope)\" refused")
                continue
            }
            scope.write(op.key, op.value, sessionID: sessionID)
        }
    }

    @ObservationIgnored private var ubiquitousObserver: (any NSObjectProtocol)?

    private func watchUbiquitousChanges(_ backend: UbiquitousBackend) {
        guard ubiquitousObserver == nil else { return }
        ubiquitousObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default, queue: .main
        ) { [weak self] note in
            let scopes = backend.changedScopes(in: note)
            Task { @MainActor in
                guard let self else { return }
                for name in scopes { self.scopes[name]?.reloadFromBackend() }
            }
        }
    }

    // The single write path. Scope calls this.
    func commit(_ scope: Scope, key: String, value: JSONValue?, sessionID: String?) {
        seq += 1
        onChange?(StoreChange(scope: scope.name, key: key, value: value, origin: Origin(session: sessionID, seq: seq)))
    }
}
