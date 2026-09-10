import Sash
import SwiftUI

/// The toolbar recipe: read the focused session's context, send commands.
struct ClockToolbar: ToolbarContent {
    let host: Sash.Host

    private var context: Context? { host.focused?.context }

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                host.send("clock.add")
            } label: {
                Label("Add City", systemImage: "plus")
            }
            .disabled(!(context?.handles("clock.add") ?? false))
            .help("Add a city (⌘N)")
        }
        ToolbarItem {
            Button {
                host.send("clock.copy")
            } label: {
                Label("Copy Times", systemImage: "doc.on.doc")
            }
            .disabled(!(context?.handles("clock.copy") ?? false))
        }
    }
}
