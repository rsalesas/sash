import AppKit
import Foundation
@_exported import Sash

/// Boots real pages against a real host in offscreen windows, for tests.
public enum Harness {
    /// Whether this process can host WebKit at all. WebKit needs a window
    /// server; an SSH session without one does not have it.
    public static var canHostWebKit: Bool {
        guard CGSessionCopyCurrentDictionary() != nil else { return false }
        return true
    }

    /// Prepares the process to host web views quietly: no Dock icon, no
    /// activation.
    @MainActor
    public static func prepareProcess() {
        let app = NSApplication.shared
        if app.activationPolicy() == .regular {
            app.setActivationPolicy(.accessory)
        }
        _ = app // NSApp exists from here on, which Platform.current() reads
    }

    /// Creates a hidden session at `route` and waits until the page calls
    /// `sash.ready()`. On timeout the error carries what the page looked like.
    @MainActor
    @discardableResult
    public static func boot(_ host: SashHost, route: Route = "/", timeout: Duration = .seconds(15)) async throws -> Session {
        prepareProcess()
        let session = host.makeSession(route: route, hidden: true)
        try await session.waitUntilReady(timeout: timeout)
        return session
    }

    /// Polls `condition` until it is true or the timeout passes.
    @MainActor
    public static func waitUntil(timeout: Duration = .seconds(5), _ label: String = "condition",
                                 _ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw SessionError.timeout(label)
    }
}
