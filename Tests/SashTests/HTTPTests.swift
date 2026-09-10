import Foundation
import XCTest
@testable import Sash

final class JSONValueTests: XCTestCase {
    func testRoundTripThroughFoundationAndCodable() throws {
        let v: JSONValue = ["a": 1, "b": [true, nil, "x"], "c": ["d": 2.5]]
        let f = v.foundationObject
        XCTAssertEqual(try JSONValue(foundation: f), v)
        let data = try v.serialized()
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"a":1,"b":[true,null,"x"],"c":{"d":2.5}}"#)
        XCTAssertEqual(try JSONValue(parsing: data), v)
    }

    func testBoolsAndNumbersAreDistinguished() throws {
        let obj = try JSONSerialization.jsonObject(with: Data(#"{"t":true,"n":1}"#.utf8))
        let v = try JSONValue(foundation: obj)
        XCTAssertEqual(v["t"], .bool(true))
        XCTAssertEqual(v["n"], .number(1))
        XCTAssertEqual(v["n"]?.intValue, 1)
    }

    func testEncodableBridge() throws {
        struct P: Codable, Equatable { var name: String; var tags: [String] }
        let p = P(name: "x", tags: ["a"])
        let v = try JSONValue(encoding: p)
        XCTAssertEqual(v, ["name": "x", "tags": ["a"]])
        XCTAssertEqual(try v.decode(P.self), p)
    }
}

final class HeadersTests: XCTestCase {
    func testCaseInsensitiveAndOrdered() {
        var h: Headers = ["Content-Type": "text/html", "X-A": "1"]
        XCTAssertEqual(h["content-type"], "text/html")
        h["CONTENT-TYPE"] = "text/plain"
        XCTAssertEqual(h.entries.count, 2)
        XCTAssertEqual(h["Content-Type"], "text/plain")
        h.add("x-a", "2")
        XCTAssertEqual(h.values("X-A"), ["1", "2"])
        XCTAssertEqual(h.removingHopByHop().entries.count, 3)
        h.add("Transfer-Encoding", "chunked")
        XCTAssertFalse(h.removingHopByHop().contains("transfer-encoding"))
    }
}

final class RequestTests: XCTestCase {
    func testURLParsing() {
        let r = Request(url: URL(string: "sash://app/api/x?a=1&b=two%20words&c")!)
        XCTAssertEqual(r.path, "/api/x")
        XCTAssertEqual(r.query, ["a": "1", "b": "two words", "c": ""])
        XCTAssertEqual(Request(url: URL(string: "sash://app")!).path, "/")
    }
}

final class RouterTests: XCTestCase {
    private func handler(_ tag: String) -> RouteHandler {
        .detached { _ in .text(tag) }
    }

    private func tag(_ m: Router.Match?) async throws -> String? {
        guard let m else { return nil }
        let r = try await m.handler(Request(path: "/"))
        return String(decoding: await r.collectedBody(), as: UTF8.self)
    }

    func testPrecedenceAndParams() async throws {
        var r = Router()
        r.add(.get, "/api/*rest", handler("wild"))
        r.add(.get, "/api/:id", handler("param"))
        r.add(.get, "/api/me", handler("literal"))
        r.add(nil, "/", handler("root"))

        let lit = r.match(.get, "/api/me")
        do { let _v = try await tag(lit); XCTAssertEqual(_v, "literal") }
        let par = r.match(.get, "/api/42")
        do { let _v = try await tag(par); XCTAssertEqual(_v, "param") }
        XCTAssertEqual(par?.params, ["id": "42"])
        let wild = r.match(.get, "/api/a/b/c")
        do { let _v = try await tag(wild); XCTAssertEqual(_v, "wild") }
        XCTAssertEqual(wild?.params, ["rest": "a/b/c"])
        do { let _v = try await tag(r.match(.post, "/")); XCTAssertEqual(_v, "root") }
        XCTAssertNil(r.match(.post, "/api/me"))
        do { let _v = try await tag(r.match(.head, "/api/me")); XCTAssertEqual(_v, "literal", "HEAD falls back to GET") }
        XCTAssertNil(r.match(.get, "/nope"))
    }

    func testFirstRegisteredWinsTies() async throws {
        var r = Router()
        r.add(.get, "/x/:a", handler("first"))
        r.add(.get, "/x/:b", handler("second"))
        do { let _v = try await tag(r.match(.get, "/x/1")); XCTAssertEqual(_v, "first") }
    }

    func testReservedPrefix() {
        XCTAssertTrue(Sash.isReservedPath("/_sash/events"))
        XCTAssertTrue(Sash.isReservedPath("/_sash"))
        XCTAssertFalse(Sash.isReservedPath("/_sashimi"))
        XCTAssertFalse(Sash.isReservedPath("/api"))
    }
}

final class SSETests: XCTestCase {
    func testFraming() {
        let f = String(decoding: SSE.frame(event: "tick", data: "a\nb", id: "7"), as: UTF8.self)
        XCTAssertEqual(f, "id: 7\nevent: tick\ndata: a\ndata: b\n\n")
        XCTAssertEqual(String(decoding: SSE.comment("ok"), as: UTF8.self), ": ok\n\n")
        XCTAssertEqual(String(decoding: SSE.frame(event: "e\nvil", data: ""), as: UTF8.self), "event: e vil\ndata: \n\n")
    }

    func testStreamingResponseDeliversAndFinishes() async throws {
        let r = SSE.response { e in
            e.send("one", data: "1")
            try? e.send("two", json: ["n": 2])
        }
        XCTAssertEqual(r.headers["Content-Type"], SSE.contentType)
        let body = String(decoding: await r.collectedBody(), as: UTF8.self)
        XCTAssertEqual(body, ": ok\n\nevent: one\ndata: 1\n\nevent: two\ndata: {\"n\":2}\n\n")
    }

    func testCancellationStopsProducer() async throws {
        let stopped = Locked(false)
        let r = SSE.response { e in
            var i = 0
            while !Task.isCancelled {
                e.send(data: "\(i)"); i += 1
                try? await Task.sleep(for: .milliseconds(5))
            }
            stopped.withLock { $0 = true }
        }
        guard case .stream(let s) = r.body else { return XCTFail() }
        var it = s.makeAsyncIterator()
        _ = await it.next(); _ = await it.next()
        it = s.makeAsyncIterator() // drop the old iterator; the stream is single-consumer, so cancel via task
        let consumer = Task { for await _ in s {} }
        consumer.cancel()
        _ = await consumer.value
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(stopped.value)
    }
}
