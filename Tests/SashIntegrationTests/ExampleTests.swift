import AppKit
import Foundation
import XCTest
import SashTesting
@testable import Sash

/// Drives the example apps' real web folders through the harness.
@MainActor
final class ExampleTests: XCTestCase {
    static var examples: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Examples")
    }

    override func setUp() async throws {
        try XCTSkipUnless(Harness.canHostWebKit, "no window server")
    }

    func testCalculatorComputesFromTheKeyboard() async throws {
        let host = SashHost(web: .directory(Self.examples.appendingPathComponent("Calculator/web")), identifier: "sash.tests.calc", store: .memory)
        let session = try await Harness.boot(host)
        defer { session.end() }
        try await Harness.waitUntil { self.titleOf(session) == "Calculator" }
        let display = try await session.evaluate("""
        for (const k of ['7','*','6','Enter']) window.dispatchEvent(new KeyboardEvent('keydown', { key: k }));
        return document.getElementById('display').textContent;
        """)
        XCTAssertEqual(display, "42")
        let clicked = try await session.evaluate("""
        document.querySelector('[data-action="clear"]').click();
        for (const s of ['[data-digit="1"]','[data-op="/"]','[data-digit="4"]','[data-action="equals"]']) document.querySelector(s).click();
        return document.getElementById('display').textContent;
        """)
        XCTAssertEqual(clicked, "0.25")
        XCTAssertEqual(host.webVersion, "0.1.0")
    }

    func testWorldClockPersistsAndTalksBothWays() async throws {
        let suite = "app.sash.tests.worldclock.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let web = Self.examples.appendingPathComponent("WorldClock/web")
        let host = SashHost(web: .directory(web), identifier: "sash.tests.clock", store: .userDefaults(suite: suite)) { Clipboard() }
        let session = try await Harness.boot(host)
        try await Harness.waitUntil { self.titleOf(session) == "World Clock" }
        XCTAssertEqual(session.context.commands, ["clock.add"], "copy is not offered with no cities")

        // ⌘N from Swift opens the page's dialog; submitting adds a city.
        session.send("clock.add")
        try await Harness.waitUntil { try await session.evaluate("return document.getElementById('add').open") == true }
        _ = try await session.evaluate("""
        document.getElementById('name').value = 'Tokyo'; document.getElementById('tz').value = 'Asia/Tokyo';
        document.getElementById('addForm').requestSubmit(); return true;
        """)
        try await Harness.waitUntil { host.store.scope("local").value("cities") != nil }
        XCTAssertEqual(host.store.scope("local").get("cities"), "[{\"name\":\"Tokyo\",\"tz\":\"Asia/Tokyo\"}]")
        try await Harness.waitUntil { session.context.commands == ["clock.add", "clock.copy"] }
        XCTAssertEqual(session.context.subtitle, "1 city")

        // Settings from Swift reach the page's formatting.
        host.store.scope("settings").set("showSeconds", false)
        try await Harness.waitUntil {
            let t = try await session.evaluate("return document.querySelector('.time').textContent")
            return (t.stringValue ?? "").filter { $0 == ":" }.count == 1
        }
        // The hour cycle is the system's, reported by the platform.
        let cycle = try await session.evaluate("return sash.platform.hourCycle")
        XCTAssertEqual(cycle, .string(host.platform.hourCycle))
        XCTAssertTrue(["h12", "h23"].contains(host.platform.hourCycle))
        let emptyHidden = try await session.evaluate("return getComputedStyle(document.getElementById('empty')).display")
        XCTAssertEqual(emptyHidden, "none", "the empty state hides when there are cities")

        // Copy goes through the Clipboard extension.
        let saved = NSPasteboard.general.string(forType: .string)
        defer { if let saved { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(saved, forType: .string) } }
        session.send("clock.copy")
        try await Harness.waitUntil { NSPasteboard.general.string(forType: .string)?.hasPrefix("Tokyo: ") ?? false }

        // Relaunch: a fresh host on the same suite still has the city.
        session.end()
        let again = SashHost(web: .directory(web), identifier: "sash.tests.clock", store: .userDefaults(suite: suite)) { Clipboard() }
        let second = try await Harness.boot(again)
        defer { second.end() }
        let names = try await second.evaluate("return [...document.querySelectorAll('.clocks .name')].map(e => e.textContent)")
        XCTAssertEqual(names, ["Tokyo"])
    }

    private func titleOf(_ s: Session) -> String? { s.context.title }
}
