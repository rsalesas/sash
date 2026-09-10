import Sash
import SwiftUI

/// The smallest Sash app: a web page in a window, no extensions. Everything
/// the page can reach is the core surface.
@main
struct CalculatorApp: App {
    @State private var host = Sash.Host(web: .bundle(.main, subdirectory: "web"))

    var body: some Scene {
        WindowGroup {
            SashView(host)
                .frame(minWidth: 300, minHeight: 420)
                .navigationTitle(host.focused?.context.title ?? "Calculator")
        }
        .defaultSize(width: 320, height: 480)
        .windowResizability(.contentMinSize)
    }
}
