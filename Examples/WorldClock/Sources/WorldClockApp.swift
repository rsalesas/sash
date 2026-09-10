import Sash
import SwiftUI

/// A page that persists through the store, a Settings window bound to the
/// same store, and a toolbar and menu driven by what the page reports.
@main
struct WorldClockApp: App {
    @State private var host = Sash.Host(web: .bundle(.main, subdirectory: "web")) {
        Clipboard()
    }

    var body: some Scene {
        WindowGroup {
            ClockWindow(host: host)
        }
        .defaultSize(width: 520, height: 440)
        .commands {
            // The menu belongs to the app, so it goes to whichever window has
            // focus. The toolbar belongs to a window, so it goes to that
            // window's own session — see ClockWindow.
            CommandMenu("Clock") {
                Button("Add City…") { host.send("clock.add") }
                    .keyboardShortcut("n")
                    .disabled(!(host.focused?.context.handles("clock.add") ?? false))
                Button("Copy All Times") { host.send("clock.copy") }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(!(host.focused?.context.handles("clock.copy") ?? false))
            }
        }

        Settings {
            ClockSettings(host: host, settings: host.store.scope("settings"))
        }
    }
}

/// One window, bound to the session it owns rather than to `host.focused`,
/// which is app-wide: that way the title and the toolbar stay right while the
/// app is in the background, and a second window shows its own page.
struct ClockWindow: View {
    let host: Sash.Host
    @State private var session: Session?

    var body: some View {
        SashView(host) { session = $0 }
            .preferredColorScheme(host.colorScheme)
            .frame(minWidth: 420, minHeight: 320)
            .navigationTitle(session?.context.title ?? "World Clock")
            .navigationSubtitle(session?.context.subtitle ?? "")
            .toolbar { ClockToolbar(session: session) }
            .task {
                // This release has one setting. Anything else in the scope is
                // left over from a release that had more, so it goes.
                host.store.scope("settings").prune(keeping: ["showSeconds"])
            }
    }
}
