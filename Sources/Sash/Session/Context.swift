import Foundation

/// What a session's page is showing. Reported by the page, read by Swift to
/// drive toolbars, titles and menu enablement.
public struct Context: Sendable, Hashable, Codable {
    public var title: String?
    public var subtitle: String?
    public var view: String?
    public var selection: [String] = []
    public var dirty: Bool = false
    /// Command identifiers the page will handle if sent.
    public var commands: [String] = []

    public init() {}

    public func handles(_ command: String) -> Bool { commands.contains(command) }

    /// Applies a partial update. Keys absent stay; keys set to null reset.
    func merging(_ patch: JSONValue) -> Context {
        guard let object = patch.objectValue else { return self }
        var c = self
        for (key, value) in object {
            switch key {
            case "title": c.title = value.stringValue
            case "subtitle": c.subtitle = value.stringValue
            case "view": c.view = value.stringValue
            case "selection": c.selection = value.arrayValue?.compactMap(\.stringValue) ?? []
            case "dirty": c.dirty = value.boolValue ?? false
            case "commands": c.commands = value.arrayValue?.compactMap(\.stringValue) ?? []
            default: break
            }
        }
        return c
    }
}
