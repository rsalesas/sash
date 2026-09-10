import Foundation

/// Constants that define the private origin every Sash page lives at.
public enum Sash {
    /// The private scheme. It is not `http`, so nothing in the page's reach can
    /// touch the network by accident, and the page has an origin no other page
    /// can share.
    public static let scheme = "sash"

    /// The fixed authority. Stable so `location.host` is stable.
    public static let authority = "app"

    /// `sash://app/`
    public static let baseURL = URL(string: "\(scheme)://\(authority)/")!

    /// The version of the contract between Swift and the page. Bumped when the
    /// shape of `window.sash`, the message envelope, or a reserved path changes.
    public static let apiVersion = 1

    /// Paths under this prefix belong to the framework.
    public static let reservedPathPrefix = "/_sash/"

    /// The framework's own version, reported to the page as `sash.version.sash`.
    public static let version = "0.1.0"

    /// `Sash.Host` reads better at the call site; the class is `SashHost`
    /// because Foundation already exports a `SashHost`.
    public typealias Host = SashHost
}
