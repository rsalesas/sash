import AppKit

/// What the page is told about the machine it is on. Also mirrored into CSS
/// custom properties on `:root`.
public struct Platform: Sendable, Hashable, Codable {
    public var os: String
    public var appearance: String
    public var accent: String
    /// BCP 47, for `Intl`.
    public var locale: String
    /// `"h12"` or `"h23"`, from the system's 24-hour time setting. Pass it to
    /// `Intl.DateTimeFormat` as `hourCycle`; the locale alone does not carry it.
    public var hourCycle: String
    public var reducedMotion: Bool
    public var highContrast: Bool

    @MainActor
    static func current() -> Platform {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        // `NSApp` is nil until NSApplication is up, and a Host built in an App's
        // property initialiser asks before then. Optional-chaining to nil would
        // silently read as light on a dark system, so fall back to the global
        // setting; `Host` re-snapshots once the app has finished launching.
        let appearance: String
        if let app = NSApp {
            appearance = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
        } else {
            appearance = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? "dark" : "light"
        }
        return Platform(
            os: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            appearance: appearance,
            accent: NSColor.controlAccentColor.hexString,
            locale: Locale.current.identifier(.bcp47),
            hourCycle: Locale.current.hourCycle == .zeroToTwentyThree || Locale.current.hourCycle == .oneToTwentyFour ? "h23" : "h12",
            reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            highContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
    }
}

extension NSColor {
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded()), b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
