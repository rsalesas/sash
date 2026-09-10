import Foundation

/// Where a session is in its life.
public enum SessionState: String, Sendable, Codable {
    /// The web view exists; nothing has loaded.
    case created
    /// The document finished loading.
    case loaded
    /// The page called `sash.ready()`. Only now is context trusted.
    case ready
    /// The view went away. The web view is released.
    case ended
}
