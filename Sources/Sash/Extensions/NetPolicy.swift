import CryptoKit
import Foundation
import WebKit

/// The hosts a page may reach. Exact names or `*.suffix` patterns. This list
/// is the only network policy: it drives both the content rule list WebKit
/// enforces on the page and the checks in the `net` extension.
public struct NetAllowList: Sendable, Hashable {
    public let patterns: [String]

    public init(_ patterns: [String]) {
        self.patterns = patterns.map { $0.lowercased() }
    }

    public var isEmpty: Bool { patterns.isEmpty }

    public func allows(host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        for p in patterns {
            if p.hasPrefix("*.") {
                let suffix = String(p.dropFirst(2))
                if host == suffix || host.hasSuffix("." + suffix) { return true }
            } else if host == p {
                return true
            }
        }
        return false
    }

    public func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        return allows(host: url.host)
    }

    /// The WebKit content rule list: block every web and socket URL, then
    /// un-block each allowed host. `sash://` never matches and is untouched.
    public var ruleListJSON: String {
        var rules: [JSONValue] = [
            ["trigger": ["url-filter": "^https?://"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^wss?://"], "action": ["type": "block"]],
        ]
        for p in patterns {
            let hostRegex: String
            if p.hasPrefix("*.") {
                hostRegex = "([a-z0-9-]+\\.)*" + NSRegularExpression.escapedPattern(for: String(p.dropFirst(2)))
            } else {
                hostRegex = NSRegularExpression.escapedPattern(for: p)
            }
            // Content-blocker regexes are a small dialect: no alternation, no
            // lookaround. A resolved URL always has a path, so `/` closes the
            // host safely.
            rules.append(["trigger": ["url-filter": .string("^https?://\(hostRegex)(:[0-9]+)?/")],
                          "action": ["type": "ignore-previous-rules"]])
        }
        return String(decoding: (try? JSONValue.array(rules).serialized()) ?? Data("[]".utf8), as: UTF8.self)
    }

    var identifier: String {
        let digest = SHA256.hash(data: Data(ruleListJSON.utf8))
        return "sash.net." + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// The compiled rule list for one allow list.
@MainActor
final class NetworkPolicy {
    let allowList: NetAllowList
    private(set) var ruleList: WKContentRuleList?

    init(allowList: NetAllowList) {
        self.allowList = allowList
    }

    func compile() async {
        do {
            ruleList = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: allowList.identifier, encodedContentRuleList: allowList.ruleListJSON)
        } catch {
            // Without the list the page would be able to reach the network.
            // That is not a degraded mode; it is the one thing Sash promised
            // would not happen.
            preconditionFailure("Sash: could not compile the network rule list: \(error)")
        }
    }
}
