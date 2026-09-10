import Sash
import SwiftUI

/// The toolbar recipe: read this window's session, send commands to it.
struct ClockToolbar: ToolbarContent {
    let session: Session?

    private var context: Context? { session?.context }

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                session?.send("clock.add")
            } label: {
                Label("Add City", systemImage: "plus")
            }
            .disabled(!(context?.handles("clock.add") ?? false))
            .help("Add a city (⌘N)")
        }
        ToolbarItem {
            Button {
                session?.send("clock.copy")
            } label: {
                Label("Copy Times", systemImage: "doc.on.doc")
            }
            .disabled(!(context?.handles("clock.copy") ?? false))
        }
    }
}
