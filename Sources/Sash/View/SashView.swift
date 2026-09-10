import AppKit
import SwiftUI

/// The SwiftUI view that hosts a page. Creating one creates a session on the
/// host; removing it ends the session.
public struct SashView: NSViewRepresentable {
    let host: SashHost
    let route: Route

    public init(_ host: SashHost, route: Route = "/") {
        self.host = host
        self.route = route
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: NSViewRepresentableContext<SashView>) -> SessionContainerView {
        let session = host.makeSession(route: route)
        context.coordinator.session = session
        let container = SessionContainerView(session: session)
        return container
    }

    public func updateNSView(_ nsView: SessionContainerView, context: NSViewRepresentableContext<SashView>) {
        // A changed route navigates the existing session rather than making a
        // new one; the page keeps its state.
        if let session = context.coordinator.session, session.route != route,
           context.coordinator.lastRoute != route {
            context.coordinator.lastRoute = route
            session.webView.load(URLRequest(url: route.url))
        }
    }

    public static func dismantleNSView(_ nsView: SessionContainerView, coordinator: Coordinator) {
        coordinator.session?.end()
        coordinator.session = nil
    }

    @MainActor
    public final class Coordinator {
        var session: Session?
        var lastRoute: Route?
    }
}

/// Holds the web view and tells the host when its window becomes key, which
/// is what `host.focused` means.
public final class SessionContainerView: NSView {
    public let session: Session
    private var observers: [any NSObjectProtocol] = []

    init(session: Session) {
        self.session = session
        super.init(frame: .zero)
        let webView = session.webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        guard let window else { return }
        if session.state == .created && !session.webView.isLoading && session.webView.url == nil {
            session.load()
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameKey() }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resignedKey() }
        })
        if window.isKeyWindow { becameKey() }
    }

    private func becameKey() {
        session.host.setFocused(session)
    }

    private func resignedKey() {
        if session.host.focused === session { session.host.setFocused(nil) }
    }

    public override func removeFromSuperview() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        super.removeFromSuperview()
    }
}
