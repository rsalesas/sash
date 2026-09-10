import SwiftUI

public extension SashHost {
    /// Hand this to `.preferredColorScheme` so the window chrome follows the
    /// same choice the page does. `nil` means the system decides, which is
    /// what `.auto` asks for.
    var colorScheme: ColorScheme? {
        switch appearance {
        case .auto: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
