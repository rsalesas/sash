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

    /// The key `migrate(to:)` records progress under. Kept by `prune`.
    public static let versionKey = "__version"

    /// Drops every key not named, and returns the ones it dropped. You name
    /// what the release still has, so a setting you removed a year ago goes
    /// without anyone having to remember it existed.
    @discardableResult
    public func prune(keeping keep: Set<String>) -> [String] {
        let gone = keys.filter { !keep.contains($0) && $0 != Scope.versionKey }
        for k in gone { remove(k) }
        return gone
    }

    /// Moves a value to a new key. Does nothing when there is nothing to move,
    /// or when the destination already holds something — a rename that ran
    /// halfway must not overwrite whatever replaced it.
    @discardableResult
    public func rename(_ from: String, to: String) -> Bool {
        guard let existing = value(from), value(to) == nil else { return false }
        set(to, json: existing)
        remove(from)
        return true
    }

    /// Runs the steps this scope has not seen, once each, numbered from 1, and
    /// records how far it got. Safe to call on every launch.
    @discardableResult
    public func migrate(to version: Int, _ step: (Int) -> Void) -> Int {
        var at = get(Scope.versionKey, default: 0)
        guard at < version else { return at }
        while at < version {
            at += 1
            step(at)
        }
        set(Scope.versionKey, at)
        return at
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
