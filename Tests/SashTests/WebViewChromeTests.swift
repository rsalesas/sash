import AppKit
import WebKit
import XCTest
@testable import Sash

/// The browser affordances the view is supposed to withhold: WebKit's context
/// menu, and reload as something the user can reach.
@MainActor
final class WebViewChromeTests: XCTestCase {
    private func makeWebView() -> SashWebView {
        SashWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: WKWebViewConfiguration())
    }

    func testContextMenuIsEmptiedBeforeItOpens() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Reload", action: #selector(WKWebView.reload(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Back", action: #selector(WKWebView.goBack(_:)), keyEquivalent: ""))
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1)!

        makeWebView().willOpenMenu(menu, with: event)

        XCTAssertTrue(menu.items.isEmpty)
    }

    func testReloadActionsAreRefusedAndValidateAsDisabled() {
        let webView = makeWebView()
        for action in [#selector(WKWebView.reload(_:)), #selector(WKWebView.reloadFromOrigin(_:))] {
            let item = NSMenuItem(title: "Reload", action: action, keyEquivalent: "r")
            XCTAssertFalse(webView.validateUserInterfaceItem(item), "\(action) should validate as disabled")
        }
        // Nothing to observe but the absence of a navigation: the sender-taking
        // actions are the ones a menu drives, and they do nothing.
        webView.reload(nil)
        webView.reloadFromOrigin(nil)
        XCTAssertFalse(webView.isLoading)
    }
}
