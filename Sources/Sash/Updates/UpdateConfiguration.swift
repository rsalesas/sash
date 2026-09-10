import Foundation

/// The two update channels. Either, both, or neither.
public struct UpdateConfiguration: Sendable {
    /// The app bundle: an appcast, a verified archive, an in-place swap and a
    /// relaunch.
    public struct AppChannel: Sendable {
        public var appcastURL: URL
        public init(appcastURL: URL) { self.appcastURL = appcastURL }
    }

    /// The web layer: a signed manifest of files, downloaded into an overlay
    /// and switched in without touching the bundle.
    public struct WebChannel: Sendable {
        public var manifestURL: URL
        /// The Ed25519 public key, 32 raw bytes, that signed the manifest.
        public var publicKey: Data
        /// Where versions live. Defaults to Application Support.
        public var directory: URL?

        public init(manifestURL: URL, publicKey: Data, directory: URL? = nil) {
            self.manifestURL = manifestURL
            self.publicKey = publicKey
            self.directory = directory
        }

        /// - Parameter publicKey: base64 of the 32 raw key bytes, as printed
        ///   by `swift Tools/sash-web-release.swift keygen`.
        public init(manifestURL: URL, publicKey: String, directory: URL? = nil) {
            guard let data = Data(base64Encoded: publicKey), data.count == 32 else {
                preconditionFailure("Sash: web update public key must be 32 bytes, base64")
            }
            self.init(manifestURL: manifestURL, publicKey: data, directory: directory)
        }
    }

    public var app: AppChannel?
    public var web: WebChannel?
    /// How often the automatic check may run. A manual check ignores it.
    public var checkInterval: TimeInterval
    /// Whether to check shortly after launch.
    public var checksAutomatically: Bool
    /// How long a probe session may take to reach ready before a new web
    /// layer is judged broken and rolled back.
    public var probeTimeout: Duration

    public init(app: AppChannel? = nil, web: WebChannel? = nil,
                checkInterval: TimeInterval = 24 * 3600, checksAutomatically: Bool = true,
                probeTimeout: Duration = .seconds(15)) {
        self.app = app
        self.web = web
        self.checkInterval = checkInterval
        self.checksAutomatically = checksAutomatically
        self.probeTimeout = probeTimeout
    }
}
