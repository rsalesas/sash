import Foundation
import XCTest
@testable import Sash

final class DirectorySourceTests: XCTestCase {
    var source: DirectorySource!

    override func setUp() {
        let root = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/site")
        source = DirectorySource(root: root)
    }

    private func get(_ path: String, headers: Headers = [:], method: Request.Method = .get) async -> Response? {
        await source.respond(to: Request(method: method, path: path, headers: headers))
    }

    func testServesFilesWithTypes() async throws {
        let css = await get("/style.css")
        XCTAssertEqual(css?.status, 200)
        XCTAssertEqual(css?.headers["Content-Type"], "text/css; charset=utf-8")
        XCTAssertEqual(css?.headers["Content-Length"], "7")
        let body = String(decoding: await css!.collectedBody(), as: UTF8.self)
        XCTAssertEqual(body, "body{}\n")
        let js = await get("/app.js")
        XCTAssertEqual(js?.headers["Content-Type"], "text/javascript; charset=utf-8")
    }

    func testDirectoryAndRootServeIndex() async {
        let root = await get("/")
        XCTAssertEqual(root?.headers["Content-Type"], "text/html; charset=utf-8")
        let sub = await get("/sub")
        let subBody = await sub!.collectedBody()
        XCTAssertEqual(String(decoding: subBody, as: UTF8.self), "{\"ok\":true}\n")
    }

    func testSPAFallback() async {
        let route = await get("/clock/tokyo")
        XCTAssertEqual(route?.status, 200)
        XCTAssertEqual(route?.headers["Content-Type"], "text/html; charset=utf-8")
        let asset = await get("/missing.png")
        XCTAssertNil(asset, "an asset-looking miss passes to the next source")
        let nav = await get("/missing.png", headers: ["Accept": "text/html,*/*"])
        XCTAssertEqual(nav?.status, 200, "a navigation gets the shell even with a dot in it")
    }

    func testTraversalIsRefused() async {
        let r = await get("/../../etc/passwd")
        XCTAssertNil(r)
        let r2 = await get("/sub/../../site/style.css")
        XCTAssertNil(r2)
    }

    func testETagAndConditional() async {
        let first = await get("/style.css")
        let tag = first?.headers["ETag"]
        XCTAssertNotNil(tag)
        XCTAssertEqual(first?.headers["Cache-Control"], "no-cache")
        let again = await get("/style.css", headers: ["If-None-Match": tag!])
        XCTAssertEqual(again?.status, 304)
        let head = await get("/style.css", method: .head)
        XCTAssertEqual(head?.status, 200)
        if case .empty = head!.body {} else { XCTFail("HEAD has no body") }
        let post = await get("/style.css", method: .post)
        XCTAssertNil(post)
    }
}

final class MIMETests: XCTestCase {
    func testTable() {
        XCTAssertEqual(MIME.type(forExtension: "HTML"), "text/html; charset=utf-8")
        XCTAssertEqual(MIME.type(forExtension: "png"), "image/png")
        XCTAssertEqual(MIME.type(forExtension: "woff2"), "font/woff2")
        XCTAssertEqual(MIME.type(forExtension: "zzznotatype"), "application/octet-stream")
    }
}
