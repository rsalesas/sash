import Foundation
import os

/// The framework's log. Under the app's bundle identifier so it shows up next
/// to the app's own lines in Console.
public enum Log {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "sash", category: "sash")

    public static func debug(_ message: String) { logger.debug("\(message, privacy: .public)") }
    public static func info(_ message: String) { logger.info("\(message, privacy: .public)") }
    public static func warning(_ message: String) { logger.warning("\(message, privacy: .public)") }
    public static func error(_ message: String) { logger.error("\(message, privacy: .public)") }
}
