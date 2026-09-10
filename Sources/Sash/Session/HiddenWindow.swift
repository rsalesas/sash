import AppKit

/// A window nobody sees. A `WKWebView` outside a window is not guaranteed to
/// run timers or complete loads, and WebKit does not reliably drive a load in
/// a window that is never ordered in at all, so this one is ordered in far
/// off any screen.
@MainActor
final class HiddenWindow {
    let window: NSWindow

    init(size: NSSize = NSSize(width: 1200, height: 800)) {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    }

    func show(_ view: NSView) {
        window.contentView = view
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }
}
