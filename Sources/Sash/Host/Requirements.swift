import Foundation
import Security

/// Startup checks for what extensions say they need.
enum Requirements {
    static func check(_ requirements: [Requirement], for namespace: String) {
        for r in requirements {
            switch r {
            case .entitlement(let name):
                guard isSandboxed else { continue }
                precondition(hasEntitlement(name),
                             "Sash: extension \(namespace) needs the \(name) entitlement")
            case .infoPlistKey(let key):
                precondition(Bundle.main.object(forInfoDictionaryKey: key) != nil,
                             "Sash: extension \(namespace) needs \(key) in Info.plist")
            }
        }
    }

    static var isSandboxed: Bool { hasEntitlement("com.apple.security.app-sandbox") }

    static func hasEntitlement(_ name: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, name as CFString, nil)
        return (value as? Bool) ?? false
    }
}
