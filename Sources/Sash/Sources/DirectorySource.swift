import CryptoKit
import Foundation

/// Serves a directory. Behaves like a static host that knows it is hosting a
/// single-page app: directories serve their `index.html`, and a miss with no
/// file extension serves the root `index.html` so client-side routers work
/// on reload.
public final class DirectorySource: Source, Sendable {
    public let root: URL
    private let rootPath: String
    private let cache = Locked<[String: CachedTag]>([:])

    struct CachedTag {
        let etag: String
        let modified: Date
        let size: Int
    }

    public init(root: URL) {
        self.root = root.standardizedFileURL
        self.rootPath = self.root.path
    }

    public func respond(to request: Request) async -> Response? {
        guard request.method == .get || request.method == .head else { return nil }
        guard let file = resolve(request.path, accept: request.headers["Accept"]) else { return nil }
        guard let data = try? Data(contentsOf: file), let tag = etag(for: file, size: data.count) else { return nil }

        var headers: Headers = [
            "Content-Type": MIME.type(for: file),
            "Cache-Control": "no-cache",
            "ETag": tag,
        ]
        if let inm = request.headers["If-None-Match"], inm.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains(tag) {
            return Response(status: 304, headers: headers)
        }
        headers["Content-Length"] = String(data.count)
        if request.method == .head { return Response(status: 200, headers: headers) }
        return Response(status: 200, headers: headers, body: .data(data))
    }

    /// The file for a path, or nil when nothing should be served.
    func resolve(_ path: String, accept: String?) -> URL? {
        let fm = FileManager.default
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        // Browsers normalise `..` before sending. One that reaches us did not
        // come from a navigation, so refuse it rather than reason about it.
        if relative.split(separator: "/").contains("..") { return nil }
        var candidate = root.appendingPathComponent(relative).standardizedFileURL
        // Traversal guard. `..` in the path can walk out of the root; the
        // standardized path must still be inside it.
        guard candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/") else { return nil }

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: candidate.path, isDirectory: &isDir) {
            if isDir.boolValue {
                candidate = candidate.appendingPathComponent("index.html")
                return fm.fileExists(atPath: candidate.path) ? candidate : nil
            }
            return candidate
        }
        // Miss. A path with no extension, or a navigation, is a client-side
        // route and gets the shell; anything that looks like an asset is a 404.
        let last = candidate.lastPathComponent
        let looksLikeAsset = last.contains(".") && !last.hasSuffix(".")
        let wantsHTML = accept?.contains("text/html") ?? false
        guard !looksLikeAsset || wantsHTML else { return nil }
        let index = root.appendingPathComponent("index.html")
        return fm.fileExists(atPath: index.path) ? index : nil
    }

    private func etag(for file: URL, size: Int) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        if let cached = cache.value[file.path], cached.modified == modified, cached.size == size {
            return cached.etag
        }
        guard let data = try? Data(contentsOf: file) else { return nil }
        let digest = SHA256.hash(data: data)
        let hex = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        let etag = "\"\(hex)\""
        cache.withLock { $0[file.path] = CachedTag(etag: etag, modified: modified, size: size) }
        return etag
    }
}
