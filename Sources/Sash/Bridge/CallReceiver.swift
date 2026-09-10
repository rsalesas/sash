import Foundation
import WebKit

/// Receives `webkit.messageHandlers.sash.postMessage(...)` and replies.
///
/// A separate object rather than the session itself: the user content
/// controller retains its handlers, and the handler must not retain the
/// session, or nothing is ever released.
@MainActor
final class CallReceiver: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "sash"

    weak var session: Session?

    init(session: Session) {
        self.session = session
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let session else {
            return (CallError.unavailable("session ended").envelope.foundationObject, nil)
        }
        guard let body = message.body as? [String: Any],
              let ns = body["ns"] as? String,
              let name = body["name"] as? String else {
            return (CallError.invalidArgs("malformed envelope").envelope.foundationObject, nil)
        }
        let args: JSONValue
        do {
            args = try JSONValue(foundation: body["args"])
        } catch {
            return (CallError.invalidArgs("arguments are not JSON").envelope.foundationObject, nil)
        }
        let reply = await session.host.registry.dispatch(namespace: ns, name: name, args: args, session: session)
        return (reply.foundationObject, nil)
    }
}
