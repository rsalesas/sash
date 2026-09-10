import Foundation
import XCTest
@testable import Sash

final class NetPolicyTests: XCTestCase {
    func testMatching() {
        let list = NetAllowList(["api.example.com", "*.cdn.net", "Upper.Case"])
        XCTAssertTrue(list.allows(URL(string: "https://api.example.com/v1")!))
        XCTAssertTrue(list.allows(URL(string: "http://API.EXAMPLE.COM:8080/")!))
        XCTAssertFalse(list.allows(URL(string: "https://example.com/")!))
        XCTAssertFalse(list.allows(URL(string: "https://evil-api.example.com/")!))
        XCTAssertTrue(list.allows(URL(string: "https://a.b.cdn.net/x")!))
        XCTAssertTrue(list.allows(URL(string: "https://cdn.net/x")!))
        XCTAssertFalse(list.allows(URL(string: "https://notcdn.net/x")!))
        XCTAssertTrue(list.allows(URL(string: "https://upper.case/")!))
        XCTAssertFalse(list.allows(URL(string: "ftp://api.example.com/")!))
        XCTAssertFalse(list.allows(URL(string: "sash://app/")!))
        XCTAssertTrue(NetAllowList([]).isEmpty)
    }

    func testRuleListJSON() throws {
        let json = NetAllowList(["example.com", "*.cdn.net"]).ruleListJSON
        let rules = try JSONValue(parsing: Data(json.utf8)).arrayValue!
        XCTAssertEqual(rules.count, 4)
        XCTAssertEqual(rules[0]["action"]?["type"], "block")
        XCTAssertEqual(rules[0]["trigger"]?["url-filter"], "^https?://")
        XCTAssertEqual(rules[2]["action"]?["type"], "ignore-previous-rules")
        XCTAssertEqual(rules[2]["trigger"]?["url-filter"], "^https?://example\\.com(:[0-9]+)?/")
        XCTAssertEqual(rules[3]["trigger"]?["url-filter"], "^https?://([a-z0-9-]+\\.)*cdn\\.net(:[0-9]+)?/")
        XCTAssertEqual(NetAllowList([]).identifier, NetAllowList([]).identifier)
        XCTAssertNotEqual(NetAllowList([]).identifier, NetAllowList(["a.b"]).identifier)
    }
}
