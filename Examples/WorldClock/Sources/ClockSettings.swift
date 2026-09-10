import Sash
import SwiftUI

/// Binds straight to the store. The page watches the same scope, so flipping
/// the toggle changes the clocks while the window is still open.
struct ClockSettings: View {
    @Bindable var settings: Scope

    var body: some View {
        Form {
            Toggle("24-hour clock", isOn: settings.binding("use24h", default: false))
            Toggle("Show seconds", isOn: settings.binding("showSeconds", default: true))
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .fixedSize()
    }
}
