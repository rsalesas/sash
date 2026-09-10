import AppKit

/// What the page is told about the machine it is on. Also mirrored into CSS
/// custom properties on `:root`.
public struct Platform: Sendable, Hashable, Codable {
    public var os: String
    public var appearance: String
    public var accent: String
    public var locale: String
    public var reducedMotion: Bool
    public var highContrast: Bool

    @MainActor
    static func current() -> Platform {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let appearance = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
        return Platform(
            os: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            appearance: appearance,
            accent: NSColor.controlAccentColor.hexString,
            locale: Locale.current.identifier,
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
