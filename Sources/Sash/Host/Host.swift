import AppKit
import Observation
import WebKit

/// The object behind every page. Owns the registry, the store, the sources,
/// and the list of live sessions. Create one, usually in your `App`, and hand
/// it to as many `SashView`s as you like.
@MainActor
@Observable
public final class SashHost {
    /// Names the host's website data store and defaults; the bundle
    /// identifier unless you have two hosts.
    public let identifier: String
    public let store: Store
    public let registry: Registry
    public let webLayer: WebLayer
    public private(set) var sessions: [Session] = []
    /// The session whose window is key, if any.
    public private(set) var focused: Session?
    public private(set) var platform: Platform

    @ObservationIgnored let sources: [any Source]
    @ObservationIgnored private(set) var extensions: [any SashExtension] = []
    @ObservationIgnored private(set) var sessionScopedTypes: [any SessionScopedExtension.Type] = []
    @ObservationIgnored private var namespaces: Set<String> = []
    @ObservationIgnored private(set) var schemeHandler: SchemeHandler!
    @ObservationIgnored private var dataStore: WKWebsiteDataStore!
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    @ObservationIgnored private var colorObserver: (any NSObjectProtocol)?
    @ObservationIgnored private(set) var networkPolicy: NetworkPolicy?
    @ObservationIgnored private var policyTask: Task<Void, Never>?

    public let appVersion: String
    public let webVersion: String

    public init(web: WebLayer,
                identifier: String? = nil,
                store storeConfiguration: StoreConfiguration = .default,
                @ExtensionBuilder extensions build: () -> [any SashExtension] = { [] }) {
        self.identifier = identifier ?? Bundle.main.bundleIdentifier ?? "sash"
        self.webLayer = web
        self.sources = web.sources
        self.store = Store(configuration: storeConfiguration)
        self.registry = Registry()
        self.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        self.webVersion = SashHost.readWebVersion(web)
        self.platform = Platform.current()

        schemeHandler = SchemeHandler(host: self)
        dataStore = SashHost.makeDataStore(identifier: self.identifier)

        CoreSurface.register(in: self)
        for ext in build() { install(ext) }

        store.onChange = { [weak self] change in self?.fanOut(change) }
        observeAppearance()
        recompileNetworkPolicy()
    }

    // MARK: Network policy

    /// The allow list in force: the `Net` extension's, or nothing.
    public var networkAllowList: NetAllowList {
        (extensions.first { $0 is Net } as? Net)?.allowList ?? NetAllowList([])
    }

    private func recompileNetworkPolicy() {
        let policy = NetworkPolicy(allowList: networkAllowList)
        policyTask?.cancel()
        policyTask = Task { @MainActor [weak self] in
            await policy.compile()
            guard let self, !Task.isCancelled else { return }
            self.networkPolicy = policy
            if let list = policy.ruleList {
                for session in self.sessions {
                    session.webView.configuration.userContentController.removeAllContentRuleLists()
                    session.webView.configuration.userContentController.add(list)
                }
            }
        }
    }

    /// Resolves once the network rule list is compiled and installed. Loads
    /// wait for this so no page ever runs without it.
    func waitForNetworkPolicy() async {
        await policyTask?.value
    }

    // MARK: Extensions

    /// Installs an extension. Extensions installed after sessions exist are
    /// announced to the pages through `sash:capabilities`.
    public func install(_ ext: any SashExtension) {
        let type = type(of: ext)
        let ns = type.namespace
        precondition(!namespaces.contains(ns), "Sash: namespace \"\(ns)\" installed twice")
        for dep in type.dependencies {
            precondition(namespaces.contains(dep), "Sash: \(ns) needs \(dep) installed first")
        }
        Requirements.check(type.requirements, for: ns)
        namespaces.insert(ns)
        if let sessionType = type as? any SessionScopedExtension.Type {
            sessionScopedTypes.append(sessionType)
            // Its calls are declared once; the per-session instance is what
            // receives them. Register through a prototype so the namespace is
            // in capabilities from the start.
            registry.currentNamespace = ns
            ext.register(in: registry)
            registry.currentNamespace = nil
        } else {
            registry.currentNamespace = ns
            ext.register(in: registry)
            registry.currentNamespace = nil
            extensions.append(ext)
        }
        if ext is Net { recompileNetworkPolicy() }
        if !sessions.isEmpty {
            let caps = registry.capabilities
            for s in sessions { s.emit("sash:capabilities", caps) }
        }
    }

    func makeSessionExtensions(for session: Session) -> [any SashExtension] {
        sessionScopedTypes.map { $0.make(for: session) }
    }

    /// Runs the block with the registry namespaced to the host's own
    /// declarations, reserved paths allowed.
    func registerCore(namespace ns: String, _ body: (Registry) -> Void) {
        namespaces.insert(ns)
        registry.currentNamespace = ns
        registry.allowsReservedRoutes = true
        body(registry)
        registry.allowsReservedRoutes = false
        registry.currentNamespace = nil
    }

    // MARK: Sessions

    /// Creates a session outside SwiftUI. `hidden` puts it in an offscreen
    /// window so it loads with no UI at all.
    @discardableResult
    public func makeSession(route: Route = "/", hidden: Bool = false) -> Session {
        let session = Session(host: self, route: route, hidden: hidden)
        sessions.append(session)
        sessionDidChange(session, .created)
        if hidden { session.load() }
        return session
    }

    func remove(_ session: Session) {
        sessions.removeAll { $0 === session }
        if focused === session { focused = nil }
    }

    func setFocused(_ session: Session?) {
        guard focused !== session else { return }
        let previous = focused
        focused = session
        previous?.emit("sash:focus", json: ["focused": false])
        session?.emit("sash:focus", json: ["focused": true])
    }

    func sessionDidChange(_ session: Session, _ state: SessionState) {
        for ext in extensions { ext.session(session, didChange: state) }
        for ext in session.sessionExtensions { ext.session(session, didChange: state) }
    }

    func session(for webView: WKWebView) -> Session? {
        sessions.first { $0.webView === webView }
    }

    public func session(id: String) -> Session? {
        sessions.first { $0.id == id }
    }

    /// Pushes a named event to every session.
    public func broadcast<T: Encodable>(_ name: String, _ payload: T) {
        let json = (try? JSONValue(encoding: payload)) ?? .null
        for s in sessions { s.emit(name, json: json) }
    }

    /// Sends a command to the focused session, if there is one.
    public func send(_ command: String, payload: JSONValue? = nil) {
        focused?.send(command, payload: payload)
    }

    // MARK: Dispatch

    /// Routes first, then the source chain, then 404.
    func dispatch(_ request: Request) async -> Response {
        if let match = registry.router.match(request.method, request.path) {
            var req = request
            req.params = match.params
            do {
                return try await match.handler(req)
            } catch let error as CallError {
                return .error(error.code == "capability-missing" ? 404 : 500, code: error.code, message: error.message)
            } catch {
                Log.error("route \(match.pattern) failed: \(error)")
                return .error(500, code: "failed", message: String(describing: error))
            }
        }
        for source in sources {
            if let response = await source.respond(to: request) { return response }
        }
        return .notFound
    }

    // MARK: WebKit plumbing

    /// A configuration for one session: shared pool, data store and scheme
    /// handler; its own user content controller.
    func makeConfiguration() -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = dataStore
        c.setURLSchemeHandler(schemeHandler, forURLScheme: Sash.scheme)
        c.userContentController = WKUserContentController()
        c.preferences.isElementFullscreenEnabled = true
        if let list = networkPolicy?.ruleList { c.userContentController.add(list) }
        return c
    }

    private static func makeDataStore(identifier: String) -> WKWebsiteDataStore {
        let key = "sash.dataStore.\(identifier)"
        let uuid: UUID
        if let s = UserDefaults.standard.string(forKey: key), let u = UUID(uuidString: s) {
            uuid = u
        } else {
            uuid = UUID()
            UserDefaults.standard.set(uuid.uuidString, forKey: key)
        }
        return WKWebsiteDataStore(forIdentifier: uuid)
    }

    private static func readWebVersion(_ web: WebLayer) -> String {
        guard case .directory(let root) = web,
              let data = try? Data(contentsOf: root.appendingPathComponent("sash.json")),
              let v = try? JSONValue(parsing: data), let s = v["version"]?.stringValue else { return "0" }
        return s
    }

    // MARK: Store and appearance fan-out

    private func fanOut(_ change: StoreChange) {
        guard store.isVisible(change.scope) else { return }
        let json = (try? JSONValue(encoding: change)) ?? .null
        for s in sessions where s.id != change.origin.session {
            s.emit("sash:state", json: json)
        }
    }

    private func observeAppearance() {
        guard let app = NSApp else { return }
        appearanceObservation = app.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.platformDidChange() }
        }
        colorObserver = NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.platformDidChange() }
        }
    }

    private func platformDidChange() {
        let now = Platform.current()
        guard now != platform else { return }
        platform = now
        broadcast("sash:appearance", now)
    }
}
