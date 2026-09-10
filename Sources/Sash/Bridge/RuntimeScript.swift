import Foundation
import WebKit

/// Builds the user scripts a session runs before its document: the boot blob
/// and the runtime, then whatever extensions asked for.
enum RuntimeScript {
    struct Boot: Encodable {
        struct SessionInfo: Encodable { var id: String; var route: Route }
        struct Version: Encodable { var app: String; var web: String; var sash: String; var api: Int }
        struct State: Encodable { var seq: UInt64; var scopes: [String: [String: JSONValue]] }
        var session: SessionInfo
        var version: Version
        var platform: Platform
        var capabilities: Capabilities
        var state: State
    }

    static let runtimeSource: String = {
        guard let url = Bundle.module.url(forResource: "sash", withExtension: "js"),
              let s = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("Sash: sash.js missing from the package resources")
        }
        return s
    }()

    /// JSON that is safe to place inside a `<script>`-like context.
    static func scriptSafeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder.sash.encode(value)
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    @MainActor
    static func userScripts(for session: Session) -> [WKUserScript] {
        let host = session.host
        let boot = Boot(
            session: .init(id: session.id, route: session.route),
            version: .init(app: host.appVersion, web: host.webVersion, sash: Sash.version, api: Sash.apiVersion),
            platform: host.platform,
            capabilities: host.registry.capabilities,
            state: .init(seq: host.store.seq, scopes: host.store.snapshot())
        )
        let bootJSON = (try? scriptSafeJSON(boot)) ?? "{}"
        var start = "window.__SASH_BOOT__ = \(bootJSON);\n" + runtimeSource + "\n"
        var end = ""
        for script in host.registry.scripts {
            switch script.injection {
            case .documentStart: start += "\n;(function(){\n\(script.source)\n})();\n"
            case .documentEnd: end += "\n;(function(){\n\(script.source)\n})();\n"
            }
        }
        var scripts = [WKUserScript(source: start, injectionTime: .atDocumentStart, forMainFrameOnly: true)]
        if !end.isEmpty {
            scripts.append(WKUserScript(source: end, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        return scripts
    }
}
