#!/usr/bin/env swift
// Signs a web layer for Sash's web update channel.
//
//   swift Tools/sash-web-release.swift keygen
//       Prints a new Ed25519 key pair. Keep the private key out of the repo;
//       embed the public key in the app's UpdateConfiguration.
//
//   swift Tools/sash-web-release.swift manifest <webdir> --version 1.2.0 \
//       --base https://cdn.example.com/app/web/1.2.0/ --key <private-base64> \
//       [--api 1] [--notes "..."] [--out <dir>]
//       Writes manifest.json and manifest.json.sig into <out> (default: <webdir>).
//       Upload <webdir>'s files under --base, and both manifest files where
//       the app's manifestURL points.

import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("usage: keygen | manifest <webdir> --version V --base URL --key KEY") }
args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

switch command {
case "keygen":
    let key = Curve25519.Signing.PrivateKey()
    print("private: \(key.rawRepresentation.base64EncodedString())")
    print("public:  \(key.publicKey.rawRepresentation.base64EncodedString())")

case "manifest":
    guard let version = option("--version"), let base = option("--base"), let keyText = option("--key") else {
        fail("manifest needs --version, --base and --key")
    }
    let api = Int(option("--api") ?? "1") ?? 1
    let notes = option("--notes")
    let outDir = option("--out")
    guard let dirPath = args.first else { fail("manifest needs <webdir>") }
    let dir = URL(fileURLWithPath: dirPath, isDirectory: true).standardizedFileURL
    guard let keyData = Data(base64Encoded: keyText), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
        fail("--key is not a base64 Ed25519 private key")
    }
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { fail("cannot read \(dir.path)") }
    var files: [[String: Any]] = []
    for case let url as URL in enumerator {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
        let rel = String(url.path.dropFirst(dir.path.count + 1))
        if rel == "manifest.json" || rel == "manifest.json.sig" || rel.hasPrefix(".") || rel.contains("/.") { continue }
        let data = try! Data(contentsOf: url)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        files.append(["path": rel, "sha256": sha, "size": data.count])
    }
    files.sort { ($0["path"] as! String) < ($1["path"] as! String) }
    var manifest: [String: Any] = ["version": version, "requires": ["api": api], "base": base, "files": files]
    if let notes { manifest["notes"] = notes }
    let json = try! JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    let signature = try! key.signature(for: json).base64EncodedString()
    let out = outDir.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? dir
    try! fm.createDirectory(at: out, withIntermediateDirectories: true)
    try! json.write(to: out.appendingPathComponent("manifest.json"))
    try! Data((signature + "\n").utf8).write(to: out.appendingPathComponent("manifest.json.sig"))
    print("wrote \(out.appendingPathComponent("manifest.json").path) (\(files.count) files, version \(version))")

default:
    fail("unknown command \(command)")
}
