import Foundation
import XCTest
@testable import Sash

@MainActor
final class StoreTests: XCTestCase {
    let suite = "app.sash.tests.\(UUID().uuidString)"

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    func testMemoryScopeRoundTrip() {
        let store = Store(configuration: .memory)
        let local = store.scope("local")
        local.set("k", "v")
        XCTAssertEqual(local.get("k"), "v")
        XCTAssertEqual(store.seq, 1)
        local.set("k", "v")
        XCTAssertEqual(store.seq, 1, "unchanged writes do not bump seq")
        local.remove("k")
        XCTAssertNil(local.value("k"))
        XCTAssertEqual(store.seq, 2)
    }

    func testPruneDropsWhatTheReleaseNoLongerHas() {
        let store = Store(configuration: .memory)
        let s = store.scope("settings")
        s.set("showSeconds", true)
        s.set("use24h", true)          // a setting an older release had
        s.set(Scope.versionKey, 3)

        let gone = s.prune(keeping: ["showSeconds"])

        XCTAssertEqual(gone, ["use24h"])
        XCTAssertEqual(s.get("showSeconds"), true)
        XCTAssertNil(s.value("use24h"))
        XCTAssertEqual(s.get(Scope.versionKey), 3, "the version key survives pruning")
    }

    func testRenameMovesAValueButNeverClobbersOne() {
        let store = Store(configuration: .memory)
        let s = store.scope("settings")
        s.set("secs", true)

        XCTAssertTrue(s.rename("secs", to: "showSeconds"))
        XCTAssertEqual(s.get("showSeconds"), true)
        XCTAssertNil(s.value("secs"))

        XCTAssertFalse(s.rename("absent", to: "showSeconds"), "nothing to move")
        s.set("secs", false)
        XCTAssertFalse(s.rename("secs", to: "showSeconds"), "destination is taken")
        XCTAssertEqual(s.get("showSeconds"), true, "and it is left alone")
    }

    func testMigrateRunsEachStepOnceAndRemembers() {
        let store = Store(configuration: .memory)
        let s = store.scope("settings")
        var ran: [Int] = []

        XCTAssertEqual(s.migrate(to: 2) { ran.append($0) }, 2)
        XCTAssertEqual(ran, [1, 2])

        XCTAssertEqual(s.migrate(to: 2) { ran.append($0) }, 2)
        XCTAssertEqual(ran, [1, 2], "a second call on the same version does nothing")

        XCTAssertEqual(s.migrate(to: 4) { ran.append($0) }, 4)
        XCTAssertEqual(ran, [1, 2, 3, 4], "only the steps it has not seen")
    }

    func testTypedValues() {
        struct City: Codable, Equatable { var name: String; var tz: String }
        let store = Store(configuration: .memory)
        let s = store.scope("settings")
        s.set("cities", [City(name: "Tokyo", tz: "Asia/Tokyo")])
        XCTAssertEqual(s.get("cities", as: [City].self)?.first?.name, "Tokyo")
        s.set("n", 3)
        XCTAssertEqual(s.value("n"), .number(3))
        XCTAssertEqual(s.get("missing", default: 9), 9)
    }

    func testUserDefaultsPersistsAcrossStores() {
        let config = StoreConfiguration.userDefaults(suite: suite)
        do {
            let store = Store(configuration: config)
            store.scope("local").set("cities", ["Tokyo", "Lima"])
        }
        let again = Store(configuration: config)
        XCTAssertEqual(again.scope("local").get("cities", as: [String].self), ["Tokyo", "Lima"])
        let raw = UserDefaults(suiteName: suite)!.string(forKey: "sash.store.local")
        XCTAssertEqual(raw, #"{"cities":["Tokyo","Lima"]}"#, "inspectable with `defaults read`")
        again.scope("local").remove("cities")
        XCTAssertNil(UserDefaults(suiteName: suite)!.string(forKey: "sash.store.local"))
    }

    func testChangesAreStampedWithOrigin() {
        let store = Store(configuration: .memory)
        var changes: [StoreChange] = []
        store.onChange = { changes.append($0) }
        store.scope("local").set("a", 1)
        store.apply([StoreOp(scope: "local", key: "b", value: "2"),
                     StoreOp(scope: "local", key: "a", value: nil)], from: "S1")
        XCTAssertEqual(changes.map(\.key), ["a", "b", "a"])
        XCTAssertEqual(changes[0].origin, Origin(session: nil, seq: 1))
        XCTAssertEqual(changes[1].origin, Origin(session: "S1", seq: 2))
        XCTAssertNil(changes[2].value)
        XCTAssertEqual(store.scope("local").values, ["b": "2"])
    }

    func testPageCannotWriteSwiftOnlyScopes() {
        let store = Store(configuration: .memory)
        store.declare(ScopeConfiguration("secret"))
        store.apply([StoreOp(scope: "secret", key: "k", value: "v")], from: "S1")
        XCTAssertTrue(store.scope("secret").values.isEmpty)
        XCTAssertNil(store.snapshot()["secret"])
        XCTAssertEqual(store.snapshot(visibleOnly: false)["secret"], [:])
    }

    func testOpDecodesNullAsRemove() throws {
        let ops = try JSONDecoder().decode([StoreOp].self, from: Data(#"[{"scope":"local","key":"k","value":null},{"scope":"local","key":"j"}]"#.utf8))
        XCTAssertNil(ops[0].value)
        XCTAssertNil(ops[1].value)
    }

    func testBindingWritesThrough() {
        let store = Store(configuration: .memory)
        let b = store.scope("settings").binding("use24h", default: false)
        XCTAssertFalse(b.wrappedValue)
        b.wrappedValue = true
        XCTAssertEqual(store.scope("settings").get("use24h"), true)
        XCTAssertTrue(b.wrappedValue)
    }

    func testUndeclaredScopeIsMemorySwiftOnly() {
        let store = Store(configuration: .memory)
        let s = store.scope("typo")
        XCTAssertEqual(s.configuration.visibility, .swiftOnly)
        XCTAssertEqual(s.configuration.persistence, .memory)
    }
}
