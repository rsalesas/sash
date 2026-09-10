import AppKit
import WebKit

/// The web view a session puts on screen: a `WKWebView` with the browser
/// taken out of it.
///
/// WebKit builds a context menu of its own — Reload, Back, Forward, Services,
/// Open in New Window — and publishes `reload:` and `reloadFromOrigin:` as
/// responder actions that any menu item ends up driving. None of that belongs
/// in an app: the page is the app's interface, not a document the user
/// browses. So the menu is emptied before it can open, and reload is refused
/// wherever the user could reach it.
///
/// The page still gets its `contextmenu` event, so a page that wants a menu
/// draws its own. `Session.reload()` and the updater still reload; reloading
/// is the app's decision, not the user's.
///
/// Debug builds set `isInspectable`, so the inspector is still one Safari
/// Develop menu away.
final class SashWebView: WKWebView {
    /// WebKit hands over the menu it just built, immediately before it opens.
    /// An empty menu is one AppKit never shows.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        menu.removeAllItems()
    }

    // MARK: Reload

    override func reload(_ sender: Any?) {}

    override func reloadFromOrigin(_ sender: Any?) {}

    /// Greys out a Reload item in any menu an app happens to wire up, so it
    /// reads as unavailable rather than as broken.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(WKWebView.reload(_:)), #selector(WKWebView.reloadFromOrigin(_:)):
            return false
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}
