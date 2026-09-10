import CryptoKit
import Foundation
import XCTest
import SashTesting
@testable import Sash

/// The web-layer channel end to end against a local server: signed manifest,
/// hashed files, overlay switch, probe, rollback.
@MainActor
final class WebUpdaterTests: XCTestCase {
    var server: TestServer!
    var port: UInt16 = 0
    var key: Curve25519.Signing.PrivateKey!
    var bundleDir: URL!
    var updatesDir: URL!
    /// Served web layers by version; the handler reads this.
    let layers = Locked<[String: [String: Data]]>([:])
    let manifest = Locked<(json: Data, sig: Data)?>(nil)
    let suite = "sash.tests.updater.\(UUID().uuidString.prefix(8))"

    override func setUp() async throws {
        try XCTSkipUnless(Harness.canHostWebKit, "no window server")
        key = Curve25519.Signing.PrivateKey()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sash-upd-\(UUID().uuidString.prefix(8))")
        bundleDir = base.appendingPathComponent("bundle")
        updatesDir = base.appendingPathComponent("updates")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        try page("v1", ready: true).write(to: bundleDir.appendingPathComponent("index.html"))
        try Data(#"{"version":"1.0.0"}"#.utf8).write(to: bundleDir.appendingPathComponent("sash.json"))

        let layers = self.layers, manifest = self.manifest
        server = TestServer { req in
            if req.path == "/manifest.json", let m = manifest.value { return .data(m.json, contentType: "application/json") }
            if req.path == "/manifest.json.sig", let m = manifest.value { return .data(m.sig, contentType: "text/plain") }
            let parts = req.path.split(separator: "/").map(String.init)   // /web/<version>/<file>
            if parts.count >= 3, parts[0] == "web", let file = layers.value[parts[1]]?[parts[2...].joined(separator: "/")] {
                return .data(file, contentType: MIME.type(forExtension: (parts.last! as NSString).pathExtension))
            }
            return .notFound
        }
        port = try server.start()
    }

    override func tearDown() {
        server.stop()
        for key in ["sash.web.current.\(suite)", "sash.web.bad.\(suite)", "sash.updates.lastCheck.\(suite)"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        try? FileManager.default.removeItem(at: bundleDir.deletingLastPathComponent())
    }

    func page(_ label: String, ready: Bool) -> Data {
        Data("<!doctype html><title>\(label)</title><script>addEventListener('load', () => { \(ready ? "sash.ready()" : "/* never ready */") })</script>".utf8)
    }

    /// Publishes a layer and a signed manifest for it.
    func publish(version: String, files: [String: Data], api: Int = Sash.apiVersion, tamper: Bool = false, badSignature: Bool = false) throws {
        layers.withLock { $0[version] = files }
        let entries = files.keys.sorted().map { path -> JSONValue in
            var sha = SHA256.hash(data: files[path]!).map { String(format: "%02x", $0) }.joined()
            if tamper { sha = String(sha.reversed()) }
            return ["path": .string(path), "sha256": .string(sha), "size": .number(Double(files[path]!.count))]
        }
        let m: JSONValue = ["version": .string(version), "requires": ["api": .number(Double(api))],
                            "base": .string("http://127.0.0.1:\(port)/web/\(version)/"), "files": .array(entries)]
        let json = try m.serialized()
        let sig = try (badSignature ? Curve25519.Signing.PrivateKey() : key!).signature(for: json)
        manifest.withLock { $0 = (json, Data(sig.base64EncodedString().utf8)) }
    }

    func makeHost() -> SashHost {
        SashHost(web: .directory(bundleDir), identifier: suite, store: .memory,
                 updates: UpdateConfiguration(web: .init(manifestURL: URL(string: "http://127.0.0.1:\(port)/manifest.json")!,
                                                         publicKey: key.publicKey.rawRepresentation, directory: updatesDir),
                                              checksAutomatically: false, probeTimeout: .seconds(4)))
    }

    func testCheckInstallServeAndSurviveRelaunch() async throws {
        try publish(version: "1.1.0", files: ["index.html": page("v1.1", ready: true), "app.js": Data("// js".utf8)])
        let host = makeHost()
        let updater = try XCTUnwrap(host.updater)
        XCTAssertEqual(updater.webVersion, "1.0.0")

        let found = await updater.check()
        XCTAssertEqual(found.web?.version, "1.1.0")
        guard case .available = updater.status else { return XCTFail("\(updater.status)") }

        await updater.apply()
        guard case .installed(let web, let app, let relaunch) = updater.status else { return XCTFail("\(updater.status)") }
        XCTAssertEqual(web, "1.1.0"); XCTAssertNil(app); XCTAssertFalse(relaunch)
        XCTAssertEqual(updater.webVersion, "1.1.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: updatesDir.appendingPathComponent("1.1.0/app.js").path))

        let session = try await Harness.boot(host)
        let title = try await session.evaluate("return document.title")
        XCTAssertEqual(title, "v1.1")
        session.end()

        // A second host on the same identifier restores the overlay.
        let again = makeHost()
        XCTAssertEqual(again.updater?.webVersion, "1.1.0")
        let s2 = try await Harness.boot(again)
        defer { s2.end() }
        let t2 = try await s2.evaluate("return document.title")
        XCTAssertEqual(t2, "v1.1")
        let up = await again.updater!.check()
        XCTAssertNil(up.web, "already current")
        guard case .upToDate = again.updater!.status else { return XCTFail("\(again.updater!.status)") }
    }

    func testRefusesBadSignatureAndTamperedFiles() async throws {
        try publish(version: "1.1.0", files: ["index.html": page("x", ready: true)], badSignature: true)
        let host = makeHost()
        await host.updater!.check()
        guard case .failed(let why) = host.updater!.status else { return XCTFail("\(host.updater!.status)") }
        XCTAssertTrue(why.contains("signature"), why)

        try publish(version: "1.1.0", files: ["index.html": page("x", ready: true)], tamper: true)
        await host.updater!.check()
        await host.updater!.apply()
        guard case .failed(let why2) = host.updater!.status else { return XCTFail("\(host.updater!.status)") }
        XCTAssertTrue(why2.contains("hash mismatch"), why2)
        XCTAssertEqual(host.updater!.webVersion, "1.0.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: updatesDir.appendingPathComponent("1.1.0").path))
    }

    func testIncompatibleApiIsNotOffered() async throws {
        try publish(version: "1.1.0", files: ["index.html": page("x", ready: true)], api: Sash.apiVersion + 1)
        let host = makeHost()
        await host.updater!.check()
        guard case .failed(let why) = host.updater!.status else { return XCTFail("\(host.updater!.status)") }
        XCTAssertTrue(why.contains("incompatible"), why)
    }

    func testBrokenLayerRollsBackAndIsRemembered() async throws {
        try publish(version: "1.1.0", files: ["index.html": page("v1.1", ready: true)])
        let host = makeHost()
        await host.updater!.check(); await host.updater!.apply()
        XCTAssertEqual(host.updater!.webVersion, "1.1.0")

        try publish(version: "1.2.0", files: ["index.html": page("broken", ready: false)])
        await host.updater!.check(); await host.updater!.apply()
        guard case .failed(let why) = host.updater!.status else { return XCTFail("\(host.updater!.status)") }
        XCTAssertTrue(why.contains("did not become ready"), why)
        XCTAssertEqual(host.updater!.webVersion, "1.1.0", "rolled back to the previous overlay")
        XCTAssertFalse(FileManager.default.fileExists(atPath: updatesDir.appendingPathComponent("1.2.0").path))
        let s = try await Harness.boot(host)
        defer { s.end() }
        let title = try await s.evaluate("return document.title")
        XCTAssertEqual(title, "v1.1")

        await host.updater!.check()
        guard case .failed(let again) = host.updater!.status else { return XCTFail("\(host.updater!.status)") }
        XCTAssertTrue(again.contains("skipped"), again)
    }
}

final class AppUpdaterUnitTests: XCTestCase {
    func testVersions() {
        XCTAssertTrue(Versions.isNewer("1.2.0", than: "1.1.9"))
        XCTAssertTrue(Versions.isNewer("1.10", than: "1.9.5"))
        XCTAssertFalse(Versions.isNewer("1.2.0-beta", than: "1.2.0"))
        XCTAssertFalse(Versions.isNewer("1.2", than: "1.2.0"))
        XCTAssertTrue(Versions.isNewer("2", than: "1.99.99"))
    }

    func testAppcastDecodes() throws {
        let json = #"{"version":"0.2.0","archive":"https://dl.example.com/app/0.2.0/App.zip","sha256":"ab","notes":"hi"}"#
        let a = try JSONDecoder.sash.decode(Appcast.self, from: Data(json.utf8))
        XCTAssertEqual(a.version, "0.2.0")
        XCTAssertEqual(a.archive.host, "dl.example.com")
    }

    func testHashAndSignatureGuards() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sash-app-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("a.zip")
        try Data("zip".utf8).write(to: file)
        let good = SHA256.hash(data: Data("zip".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try AppUpdater.verifyHash(of: file, expected: good.uppercased()))
        XCTAssertThrowsError(try AppUpdater.verifyHash(of: file, expected: String(repeating: "0", count: 64)))

        // An unsigned fake bundle never satisfies a designated requirement.
        let fake = tmp.appendingPathComponent("Fake.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: fake.appendingPathComponent("Fake"))
        XCTAssertThrowsError(try AppUpdater.verifySignature(of: tmp.appendingPathComponent("Fake.app")))
        XCTAssertNotNil(AppUpdater.firstAppBundle(in: tmp))
        XCTAssertNotNil(AppUpdater.ineligibilityReason(bundleURL: URL(fileURLWithPath: "/Volumes/X/App.app")))
    }
}
