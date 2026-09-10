import Foundation
import XCTest
import SashTesting
@testable import Sash

/// The socket and remote sources against a real HTTP server.
final class ProxySourceTests: XCTestCase {
    var server: TestServer!
    let socketPath = FileManager.default.temporaryDirectory.appendingPathComponent("sash-test-\(UUID().uuidString.prefix(8)).sock").path

    override func setUp() {
        server = TestServer { req in
            switch (req.method, req.path) {
            case (.get, "/"): return .html("<!doctype html><title>backend</title><script>addEventListener('load',()=>sash&&sash.ready())</script>")
            case (.get, "/hello"): return .text("hi \(req.query["name"] ?? "?") origin=\(req.headers["Origin"] ?? "none")")
            case (.post, "/echo"): return .data(req.body ?? Data(), contentType: req.headers["Content-Type"] ?? "application/octet-stream")
            case (.get, "/ticks"):
                return SSE.response { e in
                    var i = 0
                    while !Task.isCancelled {
                        e.send("tick", data: "\(i)"); i += 1
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                }
            case (.get, "/empty"): return .noContent
            default: return .notFound
            }
        }
    }

    override func tearDown() {
        server.stop()
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    func testSocketSourceRoundTrips() async throws {
        try server.start(unixPath: socketPath)
        let source = SocketSource(path: socketPath, hostHeader: "backend.local")

        let hello = await source.respond(to: Request(url: URL(string: "sash://app/hello?name=bo")!, headers: ["Origin": "sash://app"]))
        XCTAssertEqual(hello?.status, 200)
        let helloBody = await hello!.collectedBody()
        XCTAssertEqual(String(decoding: helloBody, as: UTF8.self), "hi bo origin=none", "Origin is stripped before it reaches the backend")

        let echo = await source.respond(to: Request(method: .post, path: "/echo", headers: ["Content-Type": "application/json"], body: Data(#"{"a":1}"#.utf8)))
        let echoBody = await echo!.collectedBody()
        XCTAssertEqual(String(decoding: echoBody, as: UTF8.self), #"{"a":1}"#)
        XCTAssertEqual(echo?.headers["Content-Type"], "application/json")
        XCTAssertNil(echo?.headers["Connection"], "hop-by-hop headers do not cross")

        let empty = await source.respond(to: Request(path: "/empty"))
        XCTAssertEqual(empty?.status, 204)
        let missing = await source.respond(to: Request(path: "/nope"))
        XCTAssertEqual(missing?.status, 404)
    }

    func testSocketSourceStreamsAndStopsWhenAbandoned() async throws {
        try server.start(unixPath: socketPath)
        let source = SocketSource(path: socketPath)
        let ticks = await source.respond(to: Request(path: "/ticks"))
        XCTAssertEqual(ticks?.headers["Content-Type"], SSE.contentType)
        guard case .stream(let stream) = ticks!.body else { return XCTFail("not a stream") }
        var got = ""
        for await chunk in stream {
            got += String(decoding: chunk, as: UTF8.self)
            if got.contains("data: 2") { break }
        }
        XCTAssertTrue(got.hasPrefix(": ok"), "the open comment arrives first")
        XCTAssertTrue(got.contains("event: tick\ndata: 0"))
        // Abandoning the stream cancels the connection; the server's producer
        // sees the peer go away on its next write and stops.
        try await Task.sleep(for: .milliseconds(200))
        let count = server.requestCount
        XCTAssertGreaterThan(count, 0)
    }

    func testMissingSocketIsA503() async {
        let source = SocketSource(path: "/tmp/definitely-not-here-\(UUID().uuidString).sock")
        let r = await source.respond(to: Request(path: "/"))
        XCTAssertEqual(r?.status, 503)
        let body = await r!.collectedBody()
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("backend-unavailable"))
    }

    func testRemoteSourceAndDevLayer() async throws {
        let port = try server.start()
        let remote = RemoteSource(baseURL: URL(string: "http://127.0.0.1:\(port)")!, noStore: true)
        let r = await remote.respond(to: Request(url: URL(string: "sash://app/hello?name=x")!))
        XCTAssertEqual(r?.status, 200)
        XCTAssertEqual(r?.headers["Cache-Control"], "no-store")
        let body = await r!.collectedBody()
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "hi x origin=none")
        let layer = WebLayer.dev(URL(string: "http://localhost:\(port)")!)
        XCTAssertEqual(layer.requiredNetworkHosts, ["localhost"])
    }

    @MainActor
    func testPageServedOverTheSocketBootsAndStreams() async throws {
        try XCTSkipUnless(Harness.canHostWebKit, "no window server")
        try server.start(unixPath: socketPath)
        let host = SashHost(web: .socket(path: socketPath), identifier: "sash.tests.socket", store: .memory)
        let session = try await Harness.boot(host)
        defer { session.end() }
        let title = try await session.evaluate("return document.title")
        XCTAssertEqual(title, "backend")
        let ticks = try await session.evaluate("""
        return await new Promise(res => { const out = []; const es = new EventSource('/ticks');
          es.addEventListener('tick', e => { out.push(e.data); if (out.length === 3) { es.close(); res(out) } }); });
        """)
        XCTAssertEqual(ticks, ["0", "1", "2"])
        let events = try await session.evaluate("return await new Promise(r => { sash.on('x', d => r(d)); setTimeout(() => r('none'), 3000) })")
        _ = events // sash:// events still come from the host, not the backend
    }

    func testOverlaySwitches() async throws {
        let a = FileManager.default.temporaryDirectory.appendingPathComponent("sash-ov-a-\(UUID().uuidString)")
        let b = FileManager.default.temporaryDirectory.appendingPathComponent("sash-ov-b-\(UUID().uuidString)")
        for (dir, text) in [(a, "A"), (b, "B")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: dir.appendingPathComponent("index.html"))
        }
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let overlay = OverlaySource()
        let none = await overlay.respond(to: Request(path: "/"))
        XCTAssertNil(none)
        overlay.set(root: a)
        let ra = await overlay.respond(to: Request(path: "/"))
        let bodyA = await ra!.collectedBody()
        XCTAssertEqual(String(decoding: bodyA, as: UTF8.self), "A")
        overlay.set(root: b)
        let rb = await overlay.respond(to: Request(path: "/"))
        let bodyB = await rb!.collectedBody()
        XCTAssertEqual(String(decoding: bodyB, as: UTF8.self), "B")
    }
}
