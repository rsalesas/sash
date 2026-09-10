import AppKit
import Foundation

/// The always-present part of `window.sash`: ready, open, log, context,
/// state, sessions, and the reserved routes.
enum CoreSurface {
    struct OpenArgs: Decodable, Sendable { var url: String }
    struct LogArgs: Decodable, Sendable { var level: String?; var message: String }
    struct ApplyArgs: Decodable, Sendable { var ops: [StoreOp] }
    struct SendArgs: Decodable, Sendable { var to: String; var name: String; var payload: JSONValue? }
    struct BroadcastArgs: Decodable, Sendable { var name: String; var payload: JSONValue? }
    struct SessionInfo: Encodable, Sendable { var id: String; var route: Route; var state: SessionState; var focused: Bool; var title: String? }
    struct Snapshot: Encodable, Sendable { var seq: UInt64; var scopes: [String: [String: JSONValue]] }

    @MainActor
    static func register(in host: SashHost) {
        host.registerCore(namespace: "sash") { r in
            r.call("ready") { (session: Session) in session.markReady() }
            r.call("open") { (a: OpenArgs) in
                guard let url = URL(string: a.url) else { throw CallError.invalidArgs("not a URL") }
                WebViewDelegates.openExternally(url)
            }
            r.call("log") { (a: LogArgs, session: Session) in
                let line = "[\(session.id)] \(a.message)"
                switch a.level {
                case "error": Log.error(line)
                case "warn", "warning": Log.warning(line)
                case "debug": Log.debug(line)
                default: Log.info(line)
                }
            }
            r.route(.get, "/_sash/capabilities") { [weak host] _ in
                try .json(host?.registry.capabilities ?? Capabilities())
            }
            r.route(.get, "/_sash/sash.js") { _ in
                .text(RuntimeScript.runtimeSource, contentType: "text/javascript; charset=utf-8")
            }
            r.route(.get, "/_sash/events") { request in
                guard let session = request.session else { return .error(400, code: "no-session", message: "events need a session") }
                let last = request.headers["Last-Event-ID"].flatMap(UInt64.init)
                return SSE.response { emitter in
                    let token = await MainActor.run { () -> UUID? in
                        guard session.state != .ended else { return nil }
                        emitter.send("sash:hello", ["storeSeq": .number(Double(session.host.store.seq)),
                                                    "session": .string(session.id),
                                                    "lastEventID": .number(Double(session.events.lastID))])
                        return session.events.subscribe(emitter, after: last)
                    }
                    guard let token else { return }
                    while !Task.isCancelled, !emitter.isFinished {
                        do { try await Task.sleep(for: .seconds(25)) } catch { break }
                        emitter.comment("ping")
                    }
                    await MainActor.run { session.events.unsubscribe(token) }
                }
            }
        }

        host.registerCore(namespace: "context") { r in
            r.call("set") { (patch: JSONValue, session: Session) in session.setContext(patch) }
        }

        host.registerCore(namespace: "state") { r in
            r.call("apply") { (a: ApplyArgs, session: Session) in
                session.host.store.apply(a.ops, from: session.id)
            }
            r.call("snapshot") { (session: Session) in
                Snapshot(seq: session.host.store.seq, scopes: session.host.store.snapshot())
            }
            r.route(.get, "/_sash/state") { [weak host] _ in
                guard let host else { return .status(410) }
                return try .json(Snapshot(seq: host.store.seq, scopes: host.store.snapshot()))
            }
        }

        host.registerCore(namespace: "sessions") { r in
            r.call("list") { (session: Session) in
                session.host.sessions.map {
                    SessionInfo(id: $0.id, route: $0.route, state: $0.state, focused: $0.isFocused, title: $0.context.title)
                }
            }
            r.call("send") { (a: SendArgs, session: Session) in
                guard let target = session.host.session(id: a.to) else { throw CallError.unavailable("no session \(a.to)") }
                target.emit("sash:message", json: ["from": .string(session.id), "name": .string(a.name), "payload": a.payload ?? .null])
            }
            r.call("broadcast") { (a: BroadcastArgs, session: Session) in
                for target in session.host.sessions where target !== session {
                    target.emit("sash:message", json: ["from": .string(session.id), "name": .string(a.name), "payload": a.payload ?? .null])
                }
            }
        }
    }
}
