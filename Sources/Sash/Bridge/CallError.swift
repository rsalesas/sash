import Foundation

/// The errors a call can fail with. The codes are part of the contract; the
/// page switches on them.
public enum CallError: Error, Sendable, CustomStringConvertible {
    /// The namespace or call is not installed.
    case capabilityMissing(String)
    /// Arguments did not decode.
    case invalidArgs(String)
    /// The extension refused.
    case denied(String)
    /// The extension is installed but cannot do this right now.
    case unavailable(String)
    /// It tried and failed. `data` is anything the page might use.
    case failed(String, data: JSONValue? = nil)

    public var code: String {
        switch self {
        case .capabilityMissing: return "capability-missing"
        case .invalidArgs: return "invalid-args"
        case .denied: return "denied"
        case .unavailable: return "unavailable"
        case .failed: return "failed"
        }
    }

    public var message: String {
        switch self {
        case .capabilityMissing(let m), .invalidArgs(let m), .denied(let m), .unavailable(let m), .failed(let m, _):
            return m
        }
    }

    public var data: JSONValue? {
        if case .failed(_, let d) = self { return d }
        return nil
    }

    public var description: String { "\(code): \(message)" }

    /// The reply body for the page: `{ ok: false, error: { code, message, data } }`.
    public var envelope: JSONValue {
        var e: [String: JSONValue] = ["code": .string(code), "message": .string(message)]
        if let data { e["data"] = data }
        return ["ok": false, "error": .object(e)]
    }

    /// Wraps any error into a call error, keeping call errors as they are.
    public static func wrap(_ error: any Error) -> CallError {
        if let c = error as? CallError { return c }
        if let d = error as? DecodingError { return .invalidArgs(d.sashDescription) }
        return .failed(String(describing: error))
    }
}

extension DecodingError {
    var sashDescription: String {
        switch self {
        case .keyNotFound(let k, let c): return "missing \(path(c) + k.stringValue)"
        case .typeMismatch(let t, let c): return "\(path(c).dropLast()) is not \(t)"
        case .valueNotFound(let t, let c): return "\(path(c).dropLast()) is null, expected \(t)"
        case .dataCorrupted(let c): return c.debugDescription
        @unknown default: return String(describing: self)
        }
    }

    private func path(_ c: Context) -> String {
        c.codingPath.map(\.stringValue).joined(separator: ".") + (c.codingPath.isEmpty ? "" : ".")
    }
}

/// The successful reply body: `{ ok: true, value }`.
func successEnvelope(_ value: JSONValue) -> JSONValue { ["ok": true, "value": value] }
