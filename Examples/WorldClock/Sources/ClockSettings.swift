import Sash
import SwiftUI

/// Binds straight to the store. The page watches the same scope, so flipping
/// a control changes the clocks while the window is still open. There is no
/// 12/24-hour toggle on purpose: that is the system's setting, and the page
/// reads it from `sash.platform.hourCycle`.
struct ClockSettings: View {
    @Bindable var host: Sash.Host
    @Bindable var settings: Scope

    var body: some View {
        Form {
            Toggle("Show seconds", isOn: settings.binding("showSeconds", default: true))
            // Appearance is Sash's own: setting it moves the window chrome and
            // the page together, and it is remembered without this app storing
            // anything.
            Picker("Appearance", selection: $host.appearance) {
                Text("Light").tag(Appearance.light)
                Text("Dark").tag(Appearance.dark)
                Text("Auto").tag(Appearance.auto)
            }
            .pickerStyle(.segmented)
        }
        .preferredColorScheme(host.colorScheme)
        .formStyle(.grouped)
        .frame(width: 320)
        .fixedSize()
    }
}
