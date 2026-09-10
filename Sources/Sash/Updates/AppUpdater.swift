import AppKit
import CryptoKit
import Foundation
import Security

/// What an appcast carries. One JSON object at a stable URL.
public struct Appcast: Codable, Sendable, Equatable {
    public var version: String
    /// A zip of the `.app`, made with `ditto -c -k --keepParent`.
    public var archive: URL
    public var sha256: String
    public var archiveSize: Int?
    public var minimumSystemVersion: String?
    public var notes: String?
    /// A page for humans, if there is one.
    public var url: URL?
}

public struct AppUpdate: Sendable, Equatable {
    public let appcast: Appcast
    public var version: String { appcast.version }
    public var notes: String? { appcast.notes }
}

/// The app-bundle channel.
///
/// Downloading and swapping a bundle bypasses the Gatekeeper check the user
/// would otherwise get, so this does Gatekeeper's job: the archive's SHA-256
/// must match the appcast fetched over HTTPS, and the new bundle must satisfy
/// the running app's own designated requirement, which pins identifier,
/// team and certificate chain without anything being configured.
@MainActor
final class AppUpdater {
    let channel: UpdateConfiguration.AppChannel
    let currentVersion: String

    init(channel: UpdateConfiguration.AppChannel, currentVersion: String) {
        self.channel = channel
        self.currentVersion = currentVersion
    }

    func check() async throws -> AppUpdate? {
        let data = try await WebUpdater.fetch(channel.appcastURL)
        let appcast: Appcast
        do { appcast = try JSONDecoder.sash.decode(Appcast.self, from: data) }
        catch { throw UpdateError.badManifest(String(describing: error)) }
        guard appcast.sha256.count == 64 else { throw UpdateError.badManifest("sha256") }
        guard appcast.archive.scheme == "https" || appcast.archive.isFileURL else { throw UpdateError.badManifest("archive must be https") }
        guard Versions.isNewer(appcast.version, than: currentVersion) else { return nil }
        if let min = appcast.minimumSystemVersion, !AppUpdater.systemIsAtLeast(min) { return nil }
        return AppUpdate(appcast: appcast)
    }

    /// Why the running bundle cannot be replaced, or nil.
    nonisolated static func ineligibilityReason(bundleURL: URL = Bundle.main.bundleURL) -> String? {
        if bundleURL.path.hasPrefix("/Volumes/") { return "running from a disk image or external volume" }
        if !FileManager.default.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) {
            return "\(bundleURL.deletingLastPathComponent().path) is not writable"
        }
        if bundleURL.pathExtension != "app" { return "not running from an app bundle" }
        return nil
    }

    /// Downloads, verifies and stages the new bundle beside the current one.
    /// Returns the staged bundle. Nothing has moved yet.
    func stage(_ update: AppUpdate, progress: @MainActor (Double?) -> Void) async throws -> URL {
        if let reason = AppUpdater.ineligibilityReason() { throw UpdateError.ineligible(reason) }
        let appcast = update.appcast
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("sash-app-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let archive = staging.appendingPathComponent("archive.zip")
        try await AppUpdater.download(appcast.archive, to: archive)
        progress(nil)
        try AppUpdater.verifyHash(of: archive, expected: appcast.sha256)

        // ditto rather than an unzip library: it restores symlinks, resource
        // forks and extended attributes, so the expansion still satisfies its
        // signature.
        let expanded = staging.appendingPathComponent("expanded", isDirectory: true)
        try AppUpdater.run("/usr/bin/ditto", ["-x", "-k", archive.path, expanded.path])
        guard let newBundle = AppUpdater.firstAppBundle(in: expanded) else { throw UpdateError.installFailed("no .app in archive") }
        try AppUpdater.verifySignature(of: newBundle)
        guard let newVersion = Bundle(url: newBundle)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              Versions.isNewer(newVersion, than: currentVersion) else {
            throw UpdateError.installFailed("archive is not newer than \(currentVersion)")
        }
        guard Bundle(url: newBundle)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError.installFailed("archive is a different app")
        }
        // Beside the target, so the final move is a same-volume rename.
        let staged = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent(Bundle.main.bundleURL.deletingPathExtension().lastPathComponent + ".update.app")
        try? fm.removeItem(at: staged)
        try fm.moveItem(at: newBundle, to: staged)
        try? fm.removeItem(at: staging)
        return staged
    }

    /// Swaps the staged bundle into place and relaunches. A running bundle
    /// can be renamed, since its executable is already mapped; a detached
    /// shell waits for this process to exit, removes the old bundle and opens
    /// the new one. This method terminates the app.
    func swapAndRelaunch(staged: URL) throws -> Never {
        let fm = FileManager.default
        let target = Bundle.main.bundleURL
        let old = target.deletingLastPathComponent().appendingPathComponent(target.deletingPathExtension().lastPathComponent + ".old.app")
        try? fm.removeItem(at: old)
        do {
            try fm.moveItem(at: target, to: old)
            try fm.moveItem(at: staged, to: target)
        } catch {
            // Put things back if the second move failed.
            if !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: old, to: target) }
            throw UpdateError.installFailed(String(describing: error))
        }
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf \(AppUpdater.shellQuoted(old.path))
        open -n \(AppUpdater.shellQuoted(target.path))
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
        NSApp.terminate(nil)
        exit(0)
    }

    // MARK: Verification

    nonisolated static func verifyHash(of file: URL, expected: String) throws {
        let data = try Data(contentsOf: file)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expected.lowercased() else { throw UpdateError.hashMismatch("archive") }
    }

    /// The new bundle must satisfy the running app's designated requirement.
    /// A development build has a different chain from a Developer ID build,
    /// so a debug app will only accept debug updates, which is right.
    nonisolated static func verifySignature(of bundle: URL) throws {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { throw UpdateError.signatureInvalid("cannot read own code") }
        var selfStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic else {
            throw UpdateError.signatureInvalid("cannot read own static code")
        }
        var requirement: SecRequirement?
        let reqStatus = SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement)
        guard reqStatus == errSecSuccess, let requirement else {
            throw UpdateError.signatureInvalid("running app has no designated requirement (unsigned?)")
        }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw UpdateError.signatureInvalid("cannot read \(bundle.lastPathComponent)")
        }
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(staticCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate), requirement, &error)
        guard status == errSecSuccess else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "status \(status)"
            throw UpdateError.signatureInvalid(detail)
        }
    }

    nonisolated static func systemIsAtLeast(_ version: String) -> Bool {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return !Versions.isNewer(version, than: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
    }

    nonisolated static func firstAppBundle(in dir: URL) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        if let app = items.first(where: { $0.pathExtension == "app" }) { return app }
        for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if let app = firstAppBundle(in: item) { return app }
        }
        return nil
    }

    nonisolated static func download(_ url: URL, to destination: URL) async throws {
        let (temp, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.http(http.statusCode, url)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    nonisolated static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw UpdateError.installFailed("\(tool) exited \(p.terminationStatus): \(text)")
        }
    }

    nonisolated static func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
