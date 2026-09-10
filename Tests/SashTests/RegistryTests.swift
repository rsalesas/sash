import Foundation
import XCTest
@testable import Sash

@MainActor
final class RegistryTests: XCTestCase {
    struct Echo: SashExtension {
        static let namespace = "echo"
        struct Args: Decodable, Sendable { var text: String; var times: Int? }
        func register(in r: Registry) {
            r.call("repeat") { (a: Args) in String(repeating: a.text, count: a.times ?? 1) }
            r.call("who") { (session: Session) in session.id }
            r.call("nothing") { }
            r.call("boom") { () -> Int in throw CallError.denied("no") }
            r.call("crash") { () -> Int in struct E: Error {}; throw E() }
            r.detachedCall("slow") { (a: Args) in a.text.uppercased() }
            r.event("echoed")
            r.route(.get, "/api/echo/:word") { req in .text(req.params["word"] ?? "") }
            r.command("echo.clear", title: "Clear", key: "k")
        }
    }

    func makeRegistry() -> (Registry, Session) {
        let r = Registry()
        r.currentNamespace = Echo.namespace
        Echo().register(in: r)
        r.currentNamespace = nil
        return (r, Session(id: "S1"))
    }

    func testDispatchSuccessAndErrors() async {
        let (r, s) = makeRegistry()
        var reply = await r.dispatch(namespace: "echo", name: "repeat", args: ["text": "ab", "times": 2], session: s)
        XCTAssertEqual(reply, ["ok": true, "value": "abab"])
        reply = await r.dispatch(namespace: "echo", name: "repeat", args: ["text": "ab"], session: s)
        XCTAssertEqual(reply["value"], "ab", "defaults apply")
        reply = await r.dispatch(namespace: "echo", name: "who", args: [:], session: s)
        XCTAssertEqual(reply["value"], "S1")
        reply = await r.dispatch(namespace: "echo", name: "nothing", args: [:], session: s)
        XCTAssertEqual(reply, ["ok": true, "value": nil])
        reply = await r.dispatch(namespace: "echo", name: "slow", args: ["text": "x"], session: s)
        XCTAssertEqual(reply["value"], "X")

        reply = await r.dispatch(namespace: "echo", name: "repeat", args: ["times": 2], session: s)
        XCTAssertEqual(reply["ok"], false)
        XCTAssertEqual(reply["error"]?["code"], "invalid-args")
        XCTAssertEqual(reply["error"]?["message"], "missing text")
        reply = await r.dispatch(namespace: "echo", name: "repeat", args: ["text": 5], session: s)
        XCTAssertEqual(reply["error"]?["code"], "invalid-args")

        reply = await r.dispatch(namespace: "nope", name: "x", args: [:], session: s)
        XCTAssertEqual(reply["error"]?["code"], "capability-missing")
        XCTAssertEqual(reply["error"]?["message"], "nope")
        reply = await r.dispatch(namespace: "echo", name: "x", args: [:], session: s)
        XCTAssertEqual(reply["error"]?["message"], "echo.x")

        reply = await r.dispatch(namespace: "echo", name: "boom", args: [:], session: s)
        XCTAssertEqual(reply["error"]?["code"], "denied")
        reply = await r.dispatch(namespace: "echo", name: "crash", args: [:], session: s)
        XCTAssertEqual(reply["error"]?["code"], "failed")
    }

    func testCapabilitiesAndRoutes() async throws {
        let (r, _) = makeRegistry()
        let caps = r.capabilities
        XCTAssertEqual(caps.namespaces["echo"]?.calls, ["boom", "crash", "nothing", "repeat", "slow", "who"])
        XCTAssertEqual(caps.namespaces["echo"]?.events, ["echoed"])
        XCTAssertEqual(caps.namespaces["echo"]?.routes, ["/api/echo/:word"])
        XCTAssertTrue(caps.has("echo"))
        XCTAssertFalse(caps.has("net"))
        XCTAssertEqual(r.commands, [Command(id: "echo.clear", title: "Clear", key: "k")])

        let m = r.router.match(.get, "/api/echo/hi")
        var req = Request(path: "/api/echo/hi")
        req.params = m!.params
        let resp = try await m!.handler(req)
        let body = await resp.collectedBody()
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "hi")
    }

    func testBuilder() {
        @ExtensionBuilder func build(_ flag: Bool) -> [any SashExtension] {
            Echo()
            if flag { Echo() }
        }
        XCTAssertEqual(build(true).count, 2)
        XCTAssertEqual(build(false).count, 1)
    }
}
