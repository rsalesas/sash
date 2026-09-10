import Foundation

/// What is installed, as the page sees it. The JavaScript function table is
/// generated from this, so it is the single source of truth for `sash.has()`.
public struct Capabilities: Codable, Sendable, Hashable {
    public struct Namespace: Codable, Sendable, Hashable {
        public var calls: [String] = []
        public var events: [String] = []
        public var routes: [String] = []
    }

    public var api: Int = Sash.apiVersion
    public var namespaces: [String: Namespace] = [:]

    public func has(_ namespace: String) -> Bool { namespaces[namespace] != nil }
}
