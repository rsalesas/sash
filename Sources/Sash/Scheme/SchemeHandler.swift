import Foundation
import WebKit

/// Turns every load the web view makes into a request on the host. There is
/// no other route out of the page.
///
/// Lifted from Vaelth.app's handler. The bookkeeping is the design: an entry
/// per in-flight task, a `stopped` flag set by `stop:`, and every callback
/// into WebKit checked against it. The exception net is for the window between
/// WebKit deciding to stop a task and `stop:` reaching us, which cannot be
/// closed from this side and whose penalty would otherwise be fatal.
///
/// Head, chunks and finish are delivered in-line from one task, never
/// re-dispatched. Vaelth learned that a second hop reorders completion ahead
/// of queued body chunks and truncates the page.
@MainActor
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    private final class Live {
        let task: any WKURLSchemeTask
        var work: Task<Void, Never>?
        var stopped = false
        init(task: any WKURLSchemeTask) { self.task = task }
    }

    private unowned let host: SashHost
    private var live: [ObjectIdentifier: Live] = [:]
    #if DEBUG
    private(set) var lateCallbacks = 0
    #endif

    init(host: SashHost) {
        self.host = host
    }

    var inFlightCount: Int { live.count }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        let entry = Live(task: urlSchemeTask)
        live[key] = entry

        let urlRequest = urlSchemeTask.request
        guard let url = urlRequest.url else {
            hand(key, terminal: true) { $0.didFailWithError(URLError(.badURL)) }
            return
        }
        let method = Request.Method(urlRequest.httpMethod ?? "GET") ?? .get
        var headers = Headers()
        for (n, v) in urlRequest.allHTTPHeaderFields ?? [:] { headers.add(n, v) }
        let body = SchemeHandler.body(of: urlRequest)
        let request = Request(method: method, url: url, headers: headers, body: body, session: host.session(for: webView))

        entry.work = Task { @MainActor [weak self] in
            guard let self else { return }
            let response = await host.dispatch(request)
            let urlResponse = SchemeHandler.urlResponse(for: url, response)
            hand(key) { $0.didReceive(urlResponse) }
            if method != .head {
                switch response.body {
                case .empty:
                    break
                case .data(let data):
                    if !data.isEmpty { hand(key) { $0.didReceive(data) } }
                case .stream(let stream):
                    for await chunk in stream {
                        if Task.isCancelled { break }
                        if !chunk.isEmpty { hand(key) { $0.didReceive(chunk) } }
                    }
                }
            }
            if Task.isCancelled { forget(key); return }
            hand(key, terminal: true) { $0.didFinish() }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        guard let entry = live.removeValue(forKey: key) else { return }
        entry.stopped = true
        // Cancelling matters as much as suppressing callbacks: a stream whose
        // page stopped listening must stop being produced.
        entry.work?.cancel()
    }

    /// Calls into the scheme task, but only while it is still ours to call.
    private func hand(_ key: ObjectIdentifier, terminal: Bool = false, _ body: (any WKURLSchemeTask) -> Void) {
        guard let entry = live[key], !entry.stopped else { return }
        do {
            try withObjCExceptionsCaught { body(entry.task) }
        } catch {
            #if DEBUG
            lateCallbacks += 1
            Log.warning("WKURLSchemeTask raised after teardown (\(lateCallbacks) so far): \(error)")
            #endif
            forget(key)
            return
        }
        if terminal { forget(key) }
    }

    private func forget(_ key: ObjectIdentifier) {
        live.removeValue(forKey: key)
    }

    // MARK: Translation

    /// WebKit is known to deliver `httpBody == nil` for `fetch` through a
    /// custom scheme, handing the payload over as a stream instead. Read both.
    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 16 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buffer, maxLength: size)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    static func urlResponse(for url: URL, _ response: Response) -> URLResponse {
        let fields = response.headers.removingHopByHop().dictionary
        return HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: fields)
            ?? URLResponse(url: url, mimeType: nil, expectedContentLength: -1, textEncodingName: nil)
    }
}
