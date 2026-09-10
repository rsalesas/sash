import Foundation
import UniformTypeIdentifiers

/// Content types for served files. An explicit table for the handful of web
/// types where the system's answer is inconsistent or missing, then `UTType`.
public enum MIME {
    static let overrides: [String: String] = [
        "html": "text/html; charset=utf-8",
        "htm": "text/html; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "map": "application/json; charset=utf-8",
        "webmanifest": "application/manifest+json",
        "svg": "image/svg+xml",
        "wasm": "application/wasm",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "otf": "font/otf",
        "txt": "text/plain; charset=utf-8",
        "md": "text/markdown; charset=utf-8",
        "xml": "application/xml",
        "ico": "image/x-icon",
    ]

    public static func type(forExtension ext: String) -> String {
        let lower = ext.lowercased()
        if let o = overrides[lower] { return o }
        if let ut = UTType(filenameExtension: lower), let mime = ut.preferredMIMEType { return mime }
        return "application/octet-stream"
    }

    public static func type(for url: URL) -> String { type(forExtension: url.pathExtension) }
}
