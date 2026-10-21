import SwiftUI

struct SheetPillStyle: ViewModifier {
    var prominent = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent).buttonBorderShape(.capsule)
            } else {
                content.buttonStyle(.glass).buttonBorderShape(.capsule)
            }
        } else {
            if prominent {
                content.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            } else {
                content.buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
        }
    }
}

/// Share header layout while native buttons provide material and interaction.
struct SheetLayout<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.title2.bold())
                Spacer()
                closeButton
                    .keyboardShortcut(.cancelAction)
                    .help("关闭")
                    .accessibilityLabel("关闭")
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)
            content()
        }
    }

    @ViewBuilder
    private var closeButton: some View {
        if #available(macOS 26.0, *) {
            Button("关闭", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
        } else {
            Button("关闭", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.large)
        }
    }
}
