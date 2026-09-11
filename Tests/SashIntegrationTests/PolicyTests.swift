import AppKit
import Foundation
import XCTest
import SashTesting
@testable import Sash

@MainActor
final class PolicyTests: XCTestCase {
    static var minimal: URL { Bundle.module.resourceURL!.appendingPathComponent("Fixtures/minimal") }

    override func setUp() async throws {
        try XCTSkipUnless(Harness.canHostWebKit, "no window server")
    }

    func testPageHasNoNetworkWithoutNet() async throws {
        let host = SashHost(web: .directory(Self.minimal), identifier: "sash.tests.policy", store: .memory)
        let session = try await Harness.boot(host)
        defer { session.end() }
        XCTAssertNotNil(host.networkPolicy?.ruleList, "loads wait for the compiled list")
        let r = try await session.evaluate("""
        try { const r = await fetch('https://example.com/', { mode: 'no-cors' }); return 'fetched:' + r.status } catch (e) { return 'blocked' }
        """)
        XCTAssertEqual(r, "blocked")
        let img = try await session.evaluate("""
        return await new Promise(res => { const i = new Image(); i.onload = () => res('loaded'); i.onerror = () => res('blocked');
          i.src = 'https://www.apple.com/favicon.ico'; setTimeout(() => res('timeout'), 8000); });
        """)
        XCTAssertEqual(img, "blocked")
        // Watch the hand-off rather than perform it: this used to open
        // example.com in whatever browser the developer had, every run.
        let handed = OpenedURLs()
        let realOpener = WebViewDelegates.opener
        WebViewDelegates.opener = { handed.urls.append($0) }
        defer { WebViewDelegates.opener = realOpener }
        let nav = try await session.evaluate("location.href = 'https://example.com/'; await new Promise(r => setTimeout(r, 300)); return location.host")
        XCTAssertEqual(nav, "app", "navigation away is cancelled and the page stays")
        XCTAssertEqual(handed.urls.map(\.absoluteString), ["https://example.com/"],
                       "and the link is handed to the system instead")
        let miss = try await session.evaluate("try { await sash.net.fetch({url:'https://example.com'}); return 'ok' } catch (e) { return e.code }")
        XCTAssertEqual(miss, "capability-missing")
    }

    func testNetProxiesAllowedHostsOnly() async throws {
        let host = SashHost(web: .directory(Self.minimal), identifier: "sash.tests.policy", store: .memory) {
            Net(allow: ["example.com", "*.example.org"])
        }
        let session = try await Harness.boot(host)
        defer { session.end() }
        let denied = try await session.evaluate("try { await sash.net.fetch({url:'https://apple.com'}); return 'ok' } catch (e) { return e.code }")
        XCTAssertEqual(denied, "denied")
        let deniedRoute = try await session.evaluate("return (await fetch('/_sash/net/fetch', {method:'POST', body: JSON.stringify({url:'https://apple.com'})})).status")
        XCTAssertEqual(deniedRoute, 500)

        // Network-dependent from here.
        let reachable = (try? await URLSession.shared.data(from: URL(string: "https://example.com/")!)) != nil
        try XCTSkipUnless(reachable, "offline")
        let ok = try await session.evaluate("const r = await sash.net.fetch({url:'https://example.com/'}); return [r.status, r.encoding, r.body.includes('Example Domain')]")
        XCTAssertEqual(ok, [200, "text", true])
        // Opaque because example.com sends no CORS header; it resolving at all
        // proves the rule list let it through.
        let direct = try await session.evaluate("try { const r = await fetch('https://example.com/', { mode: 'no-cors' }); return 'fetched:' + r.type } catch (e) { return 'blocked' }")
        XCTAssertEqual(direct, "fetched:opaque", "the page's own fetch works for allowed hosts")
        let other = try await session.evaluate("try { await fetch('https://www.apple.com/', { mode: 'no-cors' }); return 'fetched' } catch (e) { return 'blocked' }")
        XCTAssertEqual(other, "blocked")
        let streamed = try await session.evaluate("const r = await fetch('/_sash/net/fetch', {method:'POST', body: JSON.stringify({url:'https://example.com/'})}); return [r.status, (await r.text()).includes('Example Domain')]")
        XCTAssertEqual(streamed, [200, true])
    }
}

@MainActor
final class ClipboardTests: XCTestCase {
    func testWriteAndRead() async throws {
        try XCTSkipUnless(Harness.canHostWebKit, "no window server")
        let host = SashHost(web: .directory(PolicyTests.minimal), identifier: "sash.tests.clip", store: .memory) { Clipboard() }
        let session = try await Harness.boot(host)
        defer { session.end() }
        let saved = NSPasteboard.general.string(forType: .string)
        defer { if let saved { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(saved, forType: .string) } }
        _ = try await session.evaluate("await sash.clipboard.writeText({ text: 'from the page' }); return true")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "from the page")
        let back = try await session.evaluate("return await sash.clipboard.readText()")
        XCTAssertEqual(back, "from the page")
    }
}

/// A box, so the recorder can be mutated from an escaping closure.
@MainActor final class OpenedURLs {
    var urls: [URL] = []
}
