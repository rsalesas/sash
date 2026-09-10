import Foundation
import XCTest
@testable import Sash

final class JSONValueDecoderTests: XCTestCase {
    struct City: Decodable, Equatable { var name: String; var tz: String; var pop: Int?; var tags: [String]; var when: Date?; var link: URL? }
    struct Wrapper: Decodable, Equatable { var cities: [City]; var flags: [String: Bool]; var any: JSONValue }

    func testDecodesNestedShapes() throws {
        let v: JSONValue = ["cities": [["name": "Tokyo", "tz": "Asia/Tokyo", "tags": [], "when": 1000, "link": "https://x.y/"]],
                            "flags": ["a": true], "any": ["k": [1, nil]]]
        let w = try JSONValueDecoder(strict: true).decode(Wrapper.self, from: v)
        XCTAssertEqual(w.cities.first?.name, "Tokyo")
        XCTAssertEqual(w.cities.first?.when, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(w.cities.first?.link?.host, "x.y")
        XCTAssertNil(w.cities.first?.pop)
        XCTAssertEqual(w.flags, ["a": true])
        XCTAssertEqual(w.any, ["k": [1, nil]])
    }

    func testStrictRejectsUnknownFieldsAtAnyDepth() {
        let top: JSONValue = ["name": "Tokyo", "tz": "Asia/Tokyo", "tags": [], "typo": 1]
        XCTAssertThrowsError(try JSONValueDecoder(strict: true).decode(City.self, from: top)) { e in
            XCTAssertEqual((e as? DecodingError)?.sashDescription, "unknown field typo")
        }
        XCTAssertNoThrow(try JSONValueDecoder(strict: false).decode(City.self, from: top))
        let nested: JSONValue = ["cities": [["name": "Tokyo", "tz": "Asia/Tokyo", "tags": [], "extra": true]], "flags": [:], "any": nil]
        XCTAssertThrowsError(try JSONValueDecoder(strict: true).decode(Wrapper.self, from: nested)) { e in
            XCTAssertEqual((e as? DecodingError)?.sashDescription, "unknown field extra")
        }
        // Dictionaries consume every key and are never "unknown".
        let dict: JSONValue = ["cities": [], "flags": ["x": true, "y": false], "any": 1]
        XCTAssertNoThrow(try JSONValueDecoder(strict: true).decode(Wrapper.self, from: dict))
    }

    func testTypeErrorsReadWell() {
        XCTAssertThrowsError(try JSONValueDecoder().decode(City.self, from: ["name": 5, "tz": "x", "tags": []])) { e in
            XCTAssertEqual((e as? DecodingError)?.sashDescription, "name is not String")
        }
        XCTAssertThrowsError(try JSONValueDecoder().decode(City.self, from: ["tz": "x", "tags": []])) { e in
            XCTAssertEqual((e as? DecodingError)?.sashDescription, "missing name")
        }
        XCTAssertThrowsError(try JSONValueDecoder().decode([Int].self, from: [1.5]))
    }
}

@MainActor
final class FilePersistenceTests: XCTestCase {
    func testFileBackendRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sash-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = StoreConfiguration(scopes: [ScopeConfiguration("notes", persistence: .file(directory: dir), visibility: .page)])
        let first = Store(configuration: config)
        first.scope("notes").set("a", ["x": 1])
        let text = try String(contentsOf: dir.appendingPathComponent("notes.json"), encoding: .utf8)
        XCTAssertEqual(text, "{\"a\":{\"x\":1}}\n")
        let again = Store(configuration: config)
        XCTAssertEqual(again.scope("notes").value("a"), ["x": 1])
        again.scope("notes").remove("a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes.json").path))
    }

    func testReloadReportsDifferences() {
        let store = Store(configuration: .memory)
        var changes: [String] = []
        store.onChange = { changes.append($0.key) }
        let s = store.scope("local")
        s.set("k", 1)
        s.reloadFromBackend()   // memory backend is empty, so k disappears
        XCTAssertNil(s.value("k"))
        XCTAssertEqual(changes, ["k", "k"])
    }
}
