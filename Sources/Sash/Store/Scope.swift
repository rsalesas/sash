import Foundation
import Observation
import SwiftUI

/// One partition of the store. Observable, so a SwiftUI view that reads it
/// re-renders when the page (or another session) writes.
@MainActor
@Observable
public final class Scope {
    public let name: String
    public let configuration: ScopeConfiguration
    public private(set) var values: [String: JSONValue]

    @ObservationIgnored private let backend: any StoreBackend
    @ObservationIgnored private weak var store: Store?

    init(name: String, configuration: ScopeConfiguration, backend: any StoreBackend, store: Store) {
        self.name = name
        self.configuration = configuration
        self.backend = backend
        self.store = store
        self.values = backend.load(scope: name)
    }

    public var keys: [String] { values.keys.sorted() }
    public var count: Int { values.count }

    public func value(_ key: String) -> JSONValue? { values[key] }

    public func get<T: Decodable>(_ key: String, as type: T.Type = T.self) -> T? {
        guard let v = values[key] else { return nil }
        if T.self == JSONValue.self { return v as? T }
        return try? v.decode(T.self)
    }

    public func get<T: Decodable>(_ key: String, default fallback: T) -> T { get(key) ?? fallback }

    /// Sets a value; nil removes.
    public func set<T: Encodable>(_ key: String, _ value: T?) {
        guard let value else { return remove(key) }
        if let json = value as? JSONValue { return set(key, json: json) }
        guard let json = try? JSONValue(encoding: value) else {
            Log.warning("store: could not encode value for \(name).\(key)")
            return
        }
        set(key, json: json)
    }

    public func set(_ key: String, json: JSONValue?) { write(key, json, sessionID: nil) }

    public func remove(_ key: String) { write(key, nil, sessionID: nil) }

    public func removeAll() {
        for k in keys { write(k, nil, sessionID: nil) }
    }

    /// A SwiftUI binding onto one key.
    public func binding<T: Codable>(_ key: String, default fallback: T) -> Binding<T> {
        Binding(
            get: { self.get(key) ?? fallback },
            set: { self.set(key, $0) }
        )
    }

    /// Re-reads persistence and reports every key that differs, as changes
    /// from nowhere in particular. Used when another device wrote.
    func reloadFromBackend() {
        let fresh = backend.load(scope: name)
        let keys = Set(values.keys).union(fresh.keys)
        for key in keys.sorted() where values[key] != fresh[key] {
            if let v = fresh[key] { values[key] = v } else { values.removeValue(forKey: key) }
            store?.commit(self, key: key, value: fresh[key], sessionID: nil)
        }
    }

    func write(_ key: String, _ value: JSONValue?, sessionID: String?) {
        if values[key] == value { return }
        if let value { values[key] = value } else { values.removeValue(forKey: key) }
        backend.save(scope: name, values: values)
        store?.commit(self, key: key, value: value, sessionID: sessionID)
    }
}
