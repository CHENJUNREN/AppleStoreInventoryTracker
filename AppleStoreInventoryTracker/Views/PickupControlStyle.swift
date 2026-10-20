import SwiftUI

/// Use native glass only for actions; older systems and reduced transparency use solid controls.
struct PickupControlStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let prominent: Bool
    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content
                .buttonStyle(.glass(.clear))
                .tint(tint)
                .foregroundStyle(tint)
        } else if prominent {
            content.buttonStyle(.borderedProminent).tint(tint)
        } else {
            content.buttonStyle(.bordered).tint(tint)
        }
    }
}
