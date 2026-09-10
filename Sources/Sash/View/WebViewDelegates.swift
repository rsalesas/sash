import AppKit
import WebKit

/// Navigation policy and page-initiated UI for one session.
///
/// Policy: only the private scheme loads in the view. Anything else is
/// cancelled and, when it is a web or mail link, handed to the system.
@MainActor
final class WebViewDelegates: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var session: Session?

    init(session: Session) {
        self.session = session
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        if url.scheme == Sash.scheme {
            // A new document is coming; give it a fresh boot snapshot.
            if navigationAction.targetFrame?.isMainFrame ?? true {
                session?.installBootScripts()
            }
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        WebViewDelegates.openExternally(url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        session?.markLoaded()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        Log.error("navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        Log.error("provisional navigation failed: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.warning("web content process terminated; reloading")
        webView.reload()
    }

    /// Opens web and mail links in the system's handler; refuses anything else.
    static func openExternally(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            NSWorkspace.shared.open(url)
        default:
            Log.warning("refused to open \(url.scheme ?? "?") URL from the page")
        }
    }

    // MARK: Page-initiated UI

    /// `target="_blank"` and `window.open`. Returning nil without opening the
    /// URL is why those links do nothing in a naive wrapper.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { WebViewDelegates.openExternally(url) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        Dialogs.present(alert, on: webView.window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        Dialogs.present(alert, on: webView.window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        Dialogs.present(alert, on: webView.window) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }
}

@MainActor
enum Dialogs {
    /// A sheet when there is a window, a modal panel when there is not. The
    /// completion always runs.
    static func present(_ alert: NSAlert, on window: NSWindow?, _ completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { response in completion(response) }
        } else {
            completion(alert.runModal())
        }
    }
}
