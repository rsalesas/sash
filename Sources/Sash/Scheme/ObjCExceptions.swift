import Foundation
import SashObjC

extension Sash {
    /// An Objective-C exception caught by ``withObjCExceptionsCaught(_:)``.
    public struct ObjCException: Error, CustomStringConvertible, Sendable {
        public let name: String
        public let reason: String?

        public var description: String {
            reason.map { "\(name): \($0)" } ?? name
        }
    }
}

/// Runs `body`, converting a raised Objective-C exception into a thrown
/// ``Sash/ObjCException`` instead of a process crash.
///
/// Used around every call into a `WKURLSchemeTask`. The `stopped` check in the
/// scheme handler is the design and handles the ordinary case; this is the net
/// for the window between WebKit deciding to stop a task and `stop:` reaching
/// us, which cannot be closed from this side.
@discardableResult
public func withObjCExceptionsCaught<R>(_ body: () throws -> R) throws -> R {
    var result: Result<R, Error>?
    var raised: NSException?
    SashCatchObjCException({
        result = Result { try body() }
    }, &raised)
    if let raised {
        throw Sash.ObjCException(name: raised.name.rawValue, reason: raised.reason)
    }
    return try result!.get()
}
