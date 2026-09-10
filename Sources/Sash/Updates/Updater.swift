import Foundation
import Observation

/// The host's update facility. Configured in Swift, observed from Swift.
/// There is no page namespace; an app that wants to show status in its page
/// writes a three-call extension over this object.
@MainActor
@Observable
public final class Updater {
    public enum Status: Equatable, Sendable {
        case idle
        case checking
        case upToDate(Date)
        case available(Available)
        case downloading(Double?)
        case verifying
        case probing
        case installing
        /// A web layer switched in, or an app bundle staged. `relaunchPending`
        /// means `relaunch()` will finish the job.
        case installed(web: String?, app: String?, relaunchPending: Bool)
        case failed(String)
    }

    public struct Available: Equatable, Sendable {
        public var app: AppUpdate?
        public var web: WebUpdate?
        public var isEmpty: Bool { app == nil && web == nil }
    }

    public let configuration: UpdateConfiguration
    public private(set) var status: Status = .idle
    public private(set) var lastChecked: Date?
    /// The web layer version being served: the overlay's, or the bundle's.
    public var webVersion: String { web?.effectiveVersion ?? host.webVersion }

    @ObservationIgnored private unowned let host: SashHost
    @ObservationIgnored private let web: WebUpdater?
    @ObservationIgnored private let app: AppUpdater?
    @ObservationIgnored private var staged: URL?
    @ObservationIgnored private var automaticTask: Task<Void, Never>?

    private var lastCheckKey: String { "sash.updates.lastCheck.\(host.identifier)" }

    init(configuration: UpdateConfiguration, host: SashHost, overlay: OverlaySource?) {
        self.configuration = configuration
        self.host = host
        self.web = configuration.web.flatMap { channel in
            overlay.map { WebUpdater(channel: channel, identifier: host.identifier, overlay: $0, bundledVersion: host.webVersion) }
        }
        self.app = configuration.app.map { AppUpdater(channel: $0, currentVersion: host.appVersion) }
        self.lastChecked = UserDefaults.standard.object(forKey: lastCheckKey) as? Date
        if configuration.checksAutomatically { scheduleAutomaticCheck() }
    }

    // MARK: Checking

    /// Looks at both channels. Sets `status` to `.available` or `.upToDate`.
    @discardableResult
    public func check() async -> Available {
        status = .checking
        var found = Available()
        var failure: String?
        if let app {
            do { found.app = try await app.check() } catch { failure = "app: \(error)" }
        }
        if let web {
            do { found.web = try await web.check() } catch { failure = (failure.map { $0 + "; " } ?? "") + "web: \(error)" }
        }
        let now = Date()
        lastChecked = now
        UserDefaults.standard.set(now, forKey: lastCheckKey)
        if !found.isEmpty {
            status = .available(found)
        } else if let failure {
            status = .failed(failure)
        } else {
            status = .upToDate(now)
        }
        return found
    }

    /// Checks if the interval has passed since the last check.
    public func checkIfDue() async {
        if let last = lastChecked, Date().timeIntervalSince(last) < configuration.checkInterval { return }
        await check()
    }

    private func scheduleAutomaticCheck() {
        automaticTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.checkIfDue()
        }
    }

    // MARK: Applying

    /// Installs whatever the last check found: the web layer first, which
    /// needs no relaunch, then the app bundle, which is staged and waits for
    /// `relaunch()`.
    public func apply() async {
        guard case .available(let found) = status else { return }
        var installedWeb: String?
        var installedApp: String?
        if let update = found.web, let web {
            do {
                installedWeb = try await install(update, with: web)
            } catch {
                status = .failed("web: \(error)")
                return
            }
        }
        if let update = found.app, let app {
            do {
                status = .downloading(nil)
                let url = try await app.stage(update) { [weak self] p in self?.status = .downloading(p) }
                staged = url
                installedApp = update.version
            } catch {
                status = .failed("app: \(error)")
                return
            }
        }
        status = .installed(web: installedWeb, app: installedApp, relaunchPending: installedApp != nil)
    }

    /// Swaps in a staged app bundle and relaunches. Terminates the process.
    public func relaunch() throws {
        guard let staged, let app else { throw UpdateError.installFailed("nothing staged") }
        try app.swapAndRelaunch(staged: staged)
    }

    private func install(_ update: WebUpdate, with web: WebUpdater) async throws -> String {
        status = .downloading(0)
        _ = try await web.download(update) { [weak self] p in self?.status = .downloading(p) }
        let previous = web.currentVersion
        status = .probing
        web.activate(update.version)
        // A hidden session must boot from the new layer and call ready. If
        // it does not, the layer is broken for this app and comes out again.
        let probe = host.makeSession(route: "/", hidden: true)
        defer { probe.end() }
        do {
            try await probe.waitUntilReady(timeout: configuration.probeTimeout)
        } catch {
            web.rollBack(from: update.version, to: previous)
            throw UpdateError.probeFailed(String(describing: error))
        }
        web.prune(keeping: [update.version] + (previous.map { [$0] } ?? []))
        let payload: JSONValue = ["version": .string(update.version)]
        host.broadcast("sash:web-updated", payload)
        return update.version
    }

    /// Reloads every visible session so it picks up the new web layer.
    public func reloadSessions() {
        for s in host.sessions where !s.isHidden { s.reload() }
    }
}
