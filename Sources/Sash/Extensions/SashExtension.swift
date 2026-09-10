import Foundation

/// Whether one instance serves the whole host or each session gets its own.
public enum ExtensionScope: Sendable {
    case host
    case session
}

/// Something an extension needs from the app bundle. Checked at startup so a
/// missing entitlement or usage string fails loudly there, not at first call.
public enum Requirement: Sendable, Hashable {
    /// An entitlement that must be present when the app is sandboxed.
    case entitlement(String)
    /// An `Info.plist` key, typically a usage description.
    case infoPlistKey(String)
}

/// The only door between the page and the system.
///
/// An extension declares calls, routes, streams, scripts, events and commands
/// under its namespace, and hears about session lifecycle. Nothing the page
/// can reach exists unless an extension declared it.
@MainActor
public protocol SashExtension {
    /// The page sees this as `sash.<namespace>`.
    static var namespace: String { get }
    static var scope: ExtensionScope { get }
    static var requirements: [Requirement] { get }
    /// Other namespaces this one needs installed first.
    static var dependencies: [String] { get }

    func register(in registry: Registry)
    func session(_ session: Session, didChange state: SessionState)
}

public extension SashExtension {
    static var scope: ExtensionScope { .host }
    static var requirements: [Requirement] { [] }
    static var dependencies: [String] { [] }
    func session(_ session: Session, didChange state: SessionState) {}
}

/// An extension instantiated once per session, with the session injected.
@MainActor
public protocol SessionScopedExtension: SashExtension {
    static func make(for session: Session) -> Self
}

public extension SessionScopedExtension {
    static var scope: ExtensionScope { .session }
}

/// Lets a host be written as a list of extensions.
@resultBuilder
public enum ExtensionBuilder {
    public static func buildExpression(_ e: any SashExtension) -> [any SashExtension] { [e] }
    public static func buildExpression(_ e: [any SashExtension]) -> [any SashExtension] { e }
    public static func buildBlock(_ parts: [any SashExtension]...) -> [any SashExtension] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [any SashExtension]?) -> [any SashExtension] { part ?? [] }
    public static func buildEither(first: [any SashExtension]) -> [any SashExtension] { first }
    public static func buildEither(second: [any SashExtension]) -> [any SashExtension] { second }
    public static func buildArray(_ parts: [[any SashExtension]]) -> [any SashExtension] { parts.flatMap { $0 } }
}
