import Sash
import SwiftUI

/// The toolbar recipe: read this window's session, send commands to it.
///
/// Which view the page is showing is not something the toolbar tracks: the page
/// offers `clock.list` while the globe is up and `clock.globe` while the list
/// is, so the command it handles *is* the state.
struct ClockToolbar: ToolbarContent {
    let session: Session?

    private var context: Context? { session?.context }
    private var showingGlobe: Bool { context?.handles("clock.list") ?? false }

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                session?.send(showingGlobe ? "clock.list" : "clock.globe")
            } label: {
                Label(showingGlobe ? "Show List" : "Show Globe",
                      systemImage: showingGlobe ? "list.bullet" : "globe")
            }
            .disabled(!(context?.handles("clock.globe") ?? false) && !showingGlobe)
            .help(showingGlobe ? "Back to the list" : "Show the globe")
        }
        ToolbarItem(placement: .primaryAction) {
            HStack { Divider() }.frame(height: 18)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                session?.send("clock.add")
            } label: {
                Label("Add City", systemImage: "plus")
            }
            .disabled(!(context?.handles("clock.add") ?? false))
            .help("Add a city (⌘N)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                session?.send("clock.copy")
            } label: {
                Label("Copy Times", systemImage: "doc.on.doc")
            }
            .disabled(!(context?.handles("clock.copy") ?? false))
        }
    }
}
