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
            SashView(host)
                .frame(minWidth: 420, minHeight: 320)
                .navigationTitle(host.focused?.context.title ?? "World Clock")
                .navigationSubtitle(host.focused?.context.subtitle ?? "")
                .toolbar { ClockToolbar(host: host) }
        }
        .defaultSize(width: 520, height: 440)
        .commands {
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
            ClockSettings(settings: host.store.scope("settings"))
        }
    }
}
