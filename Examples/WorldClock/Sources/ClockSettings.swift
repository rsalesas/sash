import Sash
import SwiftUI

/// Binds straight to the store. The page watches the same scope, so flipping
/// the toggle changes the clocks while the window is still open. There is no
/// 12/24-hour toggle on purpose: that is the system's setting, and the page
/// reads it from `sash.platform.hourCycle`.
struct ClockSettings: View {
    @Bindable var settings: Scope

    var body: some View {
        Form {
            Toggle("Show seconds", isOn: settings.binding("showSeconds", default: true))
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .fixedSize()
    }
}
