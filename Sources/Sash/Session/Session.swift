import Foundation
import Observation
import WebKit

/// One web view and everything that belongs to it: its context, its event
/// stream, its per-session extensions, and the route it started at.
@MainActor
@Observable
public final class Session: Identifiable {
    public let id: String
    public let route: Route
    public let host: SashHost
    public let isHidden: Bool
    public private(set) var state: SessionState = .created
    public private(set) var context = Context()
    /// The web view. An escape hatch for advanced use; anything done through
    /// it directly is outside what Sash promises.
    public let webView: WKWebView

    public var isFocused: Bool { host.focused === self }

    @ObservationIgnored let events = EventBus()
    @ObservationIgnored private var receiver: CallReceiver!
    @ObservationIgnored private var delegates: WebViewDelegates!
    @ObservationIgnored private var hiddenWindow: HiddenWindow?
    @ObservationIgnored private(set) var sessionExtensions: [any SashExtension] = []

    init(host: SashHost, route: Route, hidden: Bool) {
        self.id = Session.makeID()
        self.route = route
        self.host = host
        self.isHidden = hidden

        let configuration = host.makeConfiguration()
        webView = SashWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.allowsMagnification = false
        // Until the page's own stylesheet paints, the web view shows its own
        // background, and the default is white — a flash on the way into a
        // dark app. This tracks the view's appearance, so it follows an
        // override as well as the system.
        webView.underPageBackgroundColor = .textBackgroundColor
        // underPageBackgroundColor only covers the gap before WebKit paints
        // anything at all (and the rubber-band area beyond the page). Once the
        // document exists but its stylesheet hasn't loaded yet, WebKit paints
        // its own opaque white in between — the flash survives even with the
        // above set. Turning off the private drawsBackground flag stops that
        // implicit white paint, so underPageBackgroundColor keeps showing
        // through until the page's own CSS actually paints a background.
        webView.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        webView.isInspectable = true
        #endif

        receiver = CallReceiver(session: self)
        configuration.userContentController.addScriptMessageHandler(receiver, contentWorld: .page, name: CallReceiver.handlerName)
        delegates = WebViewDelegates(session: self)
        webView.navigationDelegate = delegates
        webView.uiDelegate = delegates

        sessionExtensions = host.makeSessionExtensions(for: self)
        installBootScripts()

        if hidden {
            let w = HiddenWindow()
            w.show(webView)
            hiddenWindow = w
        }
    }

    // MARK: Loading

    func load() {
        Task { @MainActor in
            await host.waitForNetworkPolicy()
            guard state == .created, webView.url == nil else { return }
            webView.load(URLRequest(url: route.url))
        }
    }

    /// Reloads the page. The boot snapshot is regenerated on the way.
    public func reload() {
        webView.reload()
    }

    /// Replaces the user scripts so the next document sees a fresh boot
    /// snapshot. Called before every main-frame navigation.
    func installBootScripts() {
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        for s in RuntimeScript.userScripts(for: self) { ucc.addUserScript(s) }
    }

    func markLoaded() {
        guard state == .created else { return }
        transition(to: .loaded)
    }

    func markReady() {
        guard state != .ready, state != .ended else { return }
        transition(to: .ready)
    }

    private func transition(to new: SessionState) {
        state = new
        host.sessionDidChange(self, new)
    }

    /// Resolves once the page has called `sash.ready()`.
    public func waitUntilReady(timeout: Duration = .seconds(15)) async throws {
        if state == .ready { return }
        if state == .ended { throw SessionError.ended }
        let deadline = ContinuousClock.now + timeout
        while state != .ready {
            if state == .ended { throw SessionError.ended }
            if ContinuousClock.now >= deadline { throw SessionError.timeout(await diagnosis()) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// What a stalled load looks like from the inside, for error messages.
    func diagnosis() async -> String {
        let js = """
        return { readyState: document.readyState, htmlBytes: (document.documentElement && document.documentElement.outerHTML || "").length,
                 hasSash: !!window.sash, title: document.title, url: location.href };
        """
        if let v = try? await evaluate(js, timeout: .seconds(3)) { return String(describing: v) }
        return "state=\(state.rawValue) (page did not answer)"
    }

    // MARK: Talking to the page

    /// Pushes a named event to this page.
    public func emit<T: Encodable>(_ name: String, _ payload: T) {
        emit(name, json: (try? JSONValue(encoding: payload)) ?? .null)
    }

    public func emit(_ name: String, json payload: JSONValue = .null) {
        events.emit(name, payload)
    }

    /// Sends a command the page declared it handles.
    public func send(_ command: String, payload: JSONValue? = nil) {
        emit("sash:command", json: ["id": .string(command), "payload": payload ?? .null])
    }

    /// Runs JavaScript in the page and returns its result as JSON. The script
    /// is a function body: `return` what you want back, `await` is allowed.
    public func evaluate(_ functionBody: String, timeout: Duration = .seconds(10)) async throws -> JSONValue {
        let box = EvaluationBox()
        let webView = self.webView
        let work = Task { @MainActor in
            do {
                let result = try await webView.callAsyncJavaScript(functionBody, arguments: [:], in: nil, contentWorld: .page)
                box.finish(.success(try JSONValue(foundation: result)))
            } catch {
                box.finish(.failure(error))
            }
        }
        let deadline = ContinuousClock.now + timeout
        while box.result == nil {
            if ContinuousClock.now >= deadline {
                work.cancel()
                throw SessionError.timeout("evaluate")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return try box.result!.get()
    }

    func setContext(_ patch: JSONValue) {
        let merged = context.merging(patch)
        if merged != context { context = merged }
    }

    // MARK: Ending

    /// Ends the session: closes streams, detaches from WebKit, releases the
    /// web view. Idempotent.
    public func end() {
        guard state != .ended else { return }
        transition(to: .ended)
        events.finishAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        let ucc = webView.configuration.userContentController
        ucc.removeAllScriptMessageHandlers()
        ucc.removeAllUserScripts()
        hiddenWindow?.close()
        hiddenWindow = nil
        webView.removeFromSuperview()
        host.remove(self)
    }

    static func makeID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }
}

public enum SessionError: Error, CustomStringConvertible {
    case ended
    case timeout(String)

    public var description: String {
        switch self {
        case .ended: return "session ended"
        case .timeout(let d): return "timed out: \(d)"
        }
    }
}

/// Holds one asynchronous result for a poller. Main-actor only.
@MainActor
final class EvaluationBox {
    private(set) var result: Result<JSONValue, any Error>?
    func finish(_ r: Result<JSONValue, any Error>) { if result == nil { result = r } }
}
