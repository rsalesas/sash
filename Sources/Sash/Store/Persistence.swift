import Foundation

/// Where a scope's values live between launches.
public enum Persistence: Sendable, Hashable {
    case memory
    /// `UserDefaults`, one JSON string per scope under `sash.store.<scope>`.
    /// Readable with `defaults read`.
    case userDefaults(suite: String? = nil)
}

/// Whether the page may see a scope at all.
public enum Visibility: Sendable, Hashable {
    case page
    case swiftOnly
}

public struct ScopeConfiguration: Sendable, Hashable {
    public var name: String
    public var persistence: Persistence
    public var visibility: Visibility

    public init(_ name: String, persistence: Persistence = .memory, visibility: Visibility = .swiftOnly) {
        self.name = name
        self.persistence = persistence
        self.visibility = visibility
    }
}

public struct StoreConfiguration: Sendable {
    public var scopes: [ScopeConfiguration]
    public var defaultsKeyPrefix: String

    public init(scopes: [ScopeConfiguration], defaultsKeyPrefix: String = "sash.store.") {
        self.scopes = scopes
        self.defaultsKeyPrefix = defaultsKeyPrefix
    }

    /// `local` (behind the `localStorage` shim) and `settings`, both in
    /// `UserDefaults.standard`, both visible to the page.
    public static let `default` = StoreConfiguration(scopes: [
        ScopeConfiguration("local", persistence: .userDefaults(), visibility: .page),
        ScopeConfiguration("settings", persistence: .userDefaults(), visibility: .page),
    ])

    /// Everything in memory. For tests and throwaway hosts.
    public static let memory = StoreConfiguration(scopes: [
        ScopeConfiguration("local", visibility: .page),
        ScopeConfiguration("settings", visibility: .page),
    ])

    /// The default layout in a named suite, for tests that must not touch the
    /// app's own defaults.
    public static func userDefaults(suite: String) -> StoreConfiguration {
        StoreConfiguration(scopes: [
            ScopeConfiguration("local", persistence: .userDefaults(suite: suite), visibility: .page),
            ScopeConfiguration("settings", persistence: .userDefaults(suite: suite), visibility: .page),
        ])
    }
}

protocol StoreBackend: Sendable {
    func load(scope: String) -> [String: JSONValue]
    func save(scope: String, values: [String: JSONValue])
}

struct MemoryBackend: StoreBackend {
    func load(scope: String) -> [String: JSONValue] { [:] }
    func save(scope: String, values: [String: JSONValue]) {}
}

struct UserDefaultsBackend: StoreBackend, @unchecked Sendable {
    // UserDefaults is thread-safe; the annotation is missing, not the guarantee.
    let defaults: UserDefaults
    let prefix: String

    init(suite: String?, prefix: String) {
        defaults = suite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.prefix = prefix
    }

    func load(scope: String) -> [String: JSONValue] {
        guard let text = defaults.string(forKey: prefix + scope),
              let value = try? JSONValue(parsing: Data(text.utf8)),
              let object = value.objectValue else { return [:] }
        return object
    }

    func save(scope: String, values: [String: JSONValue]) {
        if values.isEmpty {
            defaults.removeObject(forKey: prefix + scope)
            return
        }
        guard let data = try? JSONValue.object(values).serialized() else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: prefix + scope)
    }
}
