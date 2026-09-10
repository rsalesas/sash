import CryptoKit
import Foundation

/// The web-layer channel.
///
/// A manifest lists files with hashes and is signed with Ed25519; the key is
/// in the app, so a CDN or a network path cannot substitute a page. Files
/// land in a versioned directory, the overlay switches to it, and a hidden
/// probe session must reach `sash.ready()` before anyone sees it. If the
/// probe fails, the previous layer comes back and the version is remembered
/// as bad.
public struct WebManifest: Codable, Sendable, Equatable {
    public struct File: Codable, Sendable, Equatable {
        public var path: String
        public var sha256: String
        public var size: Int?
    }
    public struct Requires: Codable, Sendable, Equatable {
        /// The contract version the layer was written against. The app must
        /// be at least this.
        public var api: Int
    }

    public var version: String
    public var requires: Requires
    /// Files are fetched relative to this. Absent means relative to the
    /// manifest.
    public var base: URL?
    public var files: [File]
    public var notes: String?
}

public struct WebUpdate: Sendable, Equatable {
    public let manifest: WebManifest
    public var version: String { manifest.version }
    public var notes: String? { manifest.notes }
    let manifestData: Data
    let manifestURL: URL
}

public enum UpdateError: Error, CustomStringConvertible, Equatable {
    case badSignature
    case badManifest(String)
    case hashMismatch(String)
    case http(Int, URL)
    case incompatible(String)
    case knownBad(String)
    case probeFailed(String)
    case ineligible(String)
    case signatureInvalid(String)
    case installFailed(String)

    public var description: String {
        switch self {
        case .badSignature: return "manifest signature does not verify"
        case .badManifest(let s): return "bad manifest: \(s)"
        case .hashMismatch(let s): return "hash mismatch: \(s)"
        case .http(let code, let url): return "HTTP \(code) for \(url.lastPathComponent)"
        case .incompatible(let s): return "incompatible: \(s)"
        case .knownBad(let v): return "version \(v) failed before and is skipped"
        case .probeFailed(let s): return "new web layer did not become ready: \(s)"
        case .ineligible(let s): return "cannot update: \(s)"
        case .signatureInvalid(let s): return "code signature: \(s)"
        case .installFailed(let s): return "install failed: \(s)"
        }
    }
}

@MainActor
final class WebUpdater {
    let channel: UpdateConfiguration.WebChannel
    let identifier: String
    let overlay: OverlaySource
    let bundledVersion: String
    let directory: URL
    private let defaults = UserDefaults.standard

    init(channel: UpdateConfiguration.WebChannel, identifier: String, overlay: OverlaySource, bundledVersion: String) {
        self.channel = channel
        self.identifier = identifier
        self.overlay = overlay
        self.bundledVersion = bundledVersion
        self.directory = channel.directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(identifier, isDirectory: true).appendingPathComponent("web", isDirectory: true)
        restore()
    }

    // MARK: State on disk

    private var currentKey: String { "sash.web.current.\(identifier)" }
    private var badKey: String { "sash.web.bad.\(identifier)" }

    /// The overlay version in use, or nil when the bundle serves.
    private(set) var currentVersion: String? {
        get { defaults.string(forKey: currentKey) }
        set { if let newValue { defaults.set(newValue, forKey: currentKey) } else { defaults.removeObject(forKey: currentKey) } }
    }

    var badVersions: Set<String> {
        get { Set(defaults.stringArray(forKey: badKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: badKey) }
    }

    /// The version the page is served from right now.
    var effectiveVersion: String { currentVersion ?? bundledVersion }

    func versionDirectory(_ version: String) -> URL { directory.appendingPathComponent(version, isDirectory: true) }

    /// Points the overlay at the stored current version, unless the bundle
    /// has caught up or the directory is gone.
    private func restore() {
        guard let v = currentVersion else { return }
        let dir = versionDirectory(v)
        let manifestOK = (try? Data(contentsOf: dir.appendingPathComponent("manifest.json"))).flatMap { try? JSONDecoder.sash.decode(WebManifest.self, from: $0) } != nil
        if !manifestOK || !Versions.isNewer(v, than: bundledVersion) {
            Log.info("web layer \(v) dropped: \(manifestOK ? "bundle is \(bundledVersion)" : "directory missing")")
            currentVersion = nil
            overlay.set(root: nil)
            return
        }
        overlay.set(root: dir)
    }

    // MARK: Check

    func check() async throws -> WebUpdate? {
        let manifestData = try await WebUpdater.fetch(channel.manifestURL)
        let sigURL = channel.manifestURL.appendingPathExtension("sig")
        let sigData = try await WebUpdater.fetch(sigURL)
        try verify(manifestData, signature: sigData)
        let manifest: WebManifest
        do { manifest = try JSONDecoder.sash.decode(WebManifest.self, from: manifestData) }
        catch { throw UpdateError.badManifest(String(describing: error)) }
        guard manifest.requires.api <= Sash.apiVersion else {
            throw UpdateError.incompatible("layer needs api \(manifest.requires.api), app has \(Sash.apiVersion)")
        }
        guard Versions.isNewer(manifest.version, than: effectiveVersion) else { return nil }
        guard !badVersions.contains(manifest.version) else { throw UpdateError.knownBad(manifest.version) }
        for f in manifest.files where f.sha256.count != 64 || f.path.hasPrefix("/") || f.path.split(separator: "/").contains("..") {
            throw UpdateError.badManifest("file entry \(f.path)")
        }
        return WebUpdate(manifest: manifest, manifestData: manifestData, manifestURL: channel.manifestURL)
    }

    func verify(_ data: Data, signature: Data) throws {
        let raw = Data(base64Encoded: String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? signature
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: channel.publicKey),
              key.isValidSignature(raw, for: data) else { throw UpdateError.badSignature }
    }

    // MARK: Install

    /// Downloads and verifies every file into `<version>.partial`, then
    /// renames it into place. Nothing is switched yet.
    func download(_ update: WebUpdate, progress: @MainActor (Double) -> Void) async throws -> URL {
        let manifest = update.manifest
        let final = versionDirectory(manifest.version)
        let partial = directory.appendingPathComponent(manifest.version + ".partial", isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: partial)
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        let base = manifest.base ?? update.manifestURL.deletingLastPathComponent()
        for (i, file) in manifest.files.enumerated() {
            let url = base.appendingPathComponent(file.path)
            let data = try await WebUpdater.fetch(url)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == file.sha256.lowercased() else { throw UpdateError.hashMismatch(file.path) }
            if let size = file.size, size != data.count { throw UpdateError.hashMismatch("\(file.path) size") }
            let target = partial.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            progress(Double(i + 1) / Double(max(manifest.files.count, 1)))
        }
        try update.manifestData.write(to: partial.appendingPathComponent("manifest.json"), options: .atomic)
        try? fm.removeItem(at: final)
        try fm.moveItem(at: partial, to: final)
        return final
    }

    /// Switches the overlay to `version` and remembers it.
    func activate(_ version: String) {
        currentVersion = version
        overlay.set(root: versionDirectory(version))
    }

    /// Undoes an activation and marks the version bad.
    func rollBack(from version: String, to previous: String?) {
        badVersions.insert(version)
        if let previous, previous != bundledVersion, FileManager.default.fileExists(atPath: versionDirectory(previous).path) {
            currentVersion = previous
            overlay.set(root: versionDirectory(previous))
        } else {
            currentVersion = nil
            overlay.set(root: nil)
        }
        try? FileManager.default.removeItem(at: versionDirectory(version))
    }

    /// Keeps the current and previous versions; removes the rest.
    func prune(keeping keep: [String]) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for e in entries where !keep.contains(e.lastPathComponent) && !e.lastPathComponent.hasSuffix(".partial") {
            try? fm.removeItem(at: e)
        }
    }

    nonisolated static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.http(http.statusCode, url)
        }
        return data
    }
}
