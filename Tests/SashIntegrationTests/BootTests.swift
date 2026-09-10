import Foundation
import WebKit
import XCTest
import SashTesting
@testable import Sash

/// Boots the minimal fixture in a hidden window and proves the transport.
@MainActor
final class BootTests: XCTestCase {
    var host: SashHost!
    var session: Session!

    static var fixtures: URL { Bundle.module.resourceURL!.appendingPathComponent("Fixtures") }

    override func setUp() async throws {
        try XCTSkipUnless(Harness.canHostWebKit, "no window server")
        host = SashHost(web: .directory(Self.fixtures.appendingPathComponent("minimal")), identifier: "sash.tests", store: .memory) {
            EchoExtension()
        }
        session = try await Harness.boot(host)
    }

    override func tearDown() async throws {
        session?.end()
        session = nil
        host = nil
    }

    struct EchoExtension: SashExtension {
        static let namespace = "echo"
        struct Args: Decodable, Sendable { var text: String }
        func register(in r: Registry) {
            r.call("upper") { (a: Args) in a.text.uppercased() }
            r.call("fail") { () -> Int in throw CallError.denied("nope") }
            r.route(.post, "/api/echo") { req in
                .json(["length": .number(Double(req.body?.count ?? 0)), "type": .string(req.headers["Content-Type"] ?? "")])
            }
            r.route(.get, "/api/who") { req in .text(req.session?.id ?? "none") }
            r.stream("/api/ticks") { emitter, _ in
                for i in 0..<3 { emitter.send("tick", data: "\(i)") }
            }
            r.event("echo:hello")
        }
    }

    func testLoadsAndReportsReady() async throws {
        XCTAssertEqual(session.state, .ready)
        let v = try await session.evaluate("return { title: document.title, host: location.host, path: location.pathname, hasSash: !!window.sash }")
        XCTAssertEqual(v["title"], "minimal")
        XCTAssertEqual(v["host"], "app")
        XCTAssertEqual(v["path"], "/")
        XCTAssertEqual(v["hasSash"], true)
    }

    func testCallsSucceedAndFail() async throws {
        let up = try await session.evaluate("return await sash.echo.upper({ text: 'abc' })")
        XCTAssertEqual(up, "ABC")
        let missing = try await session.evaluate("try { await sash.nothing.here(); return 'no error' } catch (e) { return e.code + ':' + e.message }")
        XCTAssertEqual(missing, "capability-missing:nothing")
        let denied = try await session.evaluate("try { await sash.echo.fail(); return 'no error' } catch (e) { return e.code }")
        XCTAssertEqual(denied, "denied")
        let bad = try await session.evaluate("try { await sash.echo.upper({}); return 'no error' } catch (e) { return e.code + ':' + e.message }")
        XCTAssertEqual(bad, "invalid-args:missing text")
        let has = try await session.evaluate("return [sash.has('echo'), sash.has('net'), sash.version.api, sash.session.id]")
        XCTAssertEqual(has, [true, false, .number(Double(Sash.apiVersion)), .string(session.id)])
    }

    func testFetchWithBodyReachesRoute() async throws {
        let v = try await session.evaluate("""
        const r = await fetch('/api/echo', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ a: 1 }) });
        return { status: r.status, json: await r.json() };
        """)
        XCTAssertEqual(v["status"], 200)
        XCTAssertEqual(v["json"]?["length"], 7)
        XCTAssertEqual(v["json"]?["type"], "application/json")
        let who = try await session.evaluate("return await (await fetch('/api/who')).text()")
        XCTAssertEqual(who, .string(session.id))
        let missing = try await session.evaluate("return (await fetch('/nope.png')).status")
        XCTAssertEqual(missing, 404)
    }

    func testEventsReachThePage() async throws {
        _ = try await session.evaluate("window.__got = []; sash.on('echo:hello', d => window.__got.push(d)); return true")
        session.emit("echo:hello", ["n": 1])
        session.emit("echo:hello", json: "two")
        try await Harness.waitUntil { try await self.session.evaluate("return window.__got.length") == 2 }
        let got = try await session.evaluate("return window.__got")
        XCTAssertEqual(got, [["n": 1], "two"])
        let ticks = try await session.evaluate("""
        return await new Promise(resolve => { const out = []; const es = new EventSource('/api/ticks');
          es.addEventListener('tick', e => { out.push(e.data); if (out.length === 3) { es.close(); resolve(out) } }); });
        """)
        XCTAssertEqual(ticks, ["0", "1", "2"])
    }

    func testCommandsAndContext() async throws {
        _ = try await session.evaluate("window.__cmd = null; sash.on('sash:command', c => window.__cmd = c); await sash.context.set({ title: 'Tokyo', commands: ['clock.add'] }); return true")
        try await Harness.waitUntil { self.session.context.title == "Tokyo" }
        XCTAssertEqual(session.context.commands, ["clock.add"])
        session.send("clock.add", payload: ["city": "Lima"])
        try await Harness.waitUntil { try await self.session.evaluate("return window.__cmd !== null") == true }
        let cmd = try await session.evaluate("return window.__cmd")
        XCTAssertEqual(cmd, ["id": "clock.add", "payload": ["city": "Lima"]])
    }

    func testStoreBridgeBothWays() async throws {
        let diag = try await session.evaluate("return sash._diagnostics.localStorageShim")
        XCTAssertEqual(diag, "window")
        _ = try await session.evaluate("localStorage.setItem('cities', JSON.stringify(['Tokyo'])); sash.state.set('settings', 'use24h', true); await sash.state.flush(); return true")
        try await Harness.waitUntil { self.host.store.scope("local").value("cities") != nil }
        XCTAssertEqual(host.store.scope("local").get("cities"), "[\"Tokyo\"]")
        XCTAssertEqual(host.store.scope("settings").get("use24h"), true)

        // Swift writes reach the page, synchronously readable.
        host.store.scope("settings").set("use24h", false)
        host.store.scope("local").set("greeting", "hi")
        try await Harness.waitUntil { try await self.session.evaluate("return sash.state.get('settings','use24h')") == false }
        let ls = try await session.evaluate("return [localStorage.getItem('greeting'), localStorage.length, 'greeting' in localStorage, Object.keys(localStorage).sort()]")
        XCTAssertEqual(ls, ["hi", 2, true, ["cities", "greeting"]])

        // A second session sees the same state at boot and gets live updates.
        let other = try await Harness.boot(host)
        defer { other.end() }
        let seen = try await other.evaluate("return localStorage.getItem('cities')")
        XCTAssertEqual(seen, "[\"Tokyo\"]")
        _ = try await other.evaluate("window.__storage = []; addEventListener('storage', e => window.__storage.push([e.key, e.newValue])); return true")
        _ = try await session.evaluate("localStorage.removeItem('greeting'); return true")
        try await Harness.waitUntil { try await other.evaluate("return window.__storage.length") == 1 }
        let ev = try await other.evaluate("return window.__storage[0]")
        XCTAssertEqual(ev, ["greeting", nil])
        XCTAssertNil(host.store.scope("local").value("greeting"))
    }

    func testReloadGetsFreshSnapshot() async throws {
        host.store.scope("local").set("before", "1")
        // Silence the live channel by reloading right away and checking the boot mirror.
        _ = try await session.evaluate("location.reload(); return true")
        try await Harness.waitUntil(timeout: .seconds(10), "reload") {
            (try? await self.session.evaluate("return document.readyState === 'complete' && !!window.sash && localStorage.getItem('before') === '1'")) == true
        }
    }

    func testEndReleasesTheWebView() async throws {
        weak var webView = session.webView
        session.end()
        XCTAssertEqual(session.state, .ended)
        XCTAssertTrue(host.sessions.isEmpty)
        session = nil
        try await Harness.waitUntil(timeout: .seconds(3), "web view release") { webView == nil }
    }
}
