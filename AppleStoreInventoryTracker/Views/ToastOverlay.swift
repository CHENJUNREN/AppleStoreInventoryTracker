import SwiftUI

/// Only the frontmost presentation hosts feedback; dismissed sheets hand it back to the window.
struct ToastOverlay: ViewModifier {
    let center: ToastCenter
    @State private var id = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if center.hosts.last == id, let message = center.message {
                    toast(message)
                        .padding(16)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: center.message?.id)
            .onAppear { center.register(id) }
            .onDisappear { center.unregister(id) }
    }

    private func toast(_ message: ToastCenter.Message) -> some View {
        HStack(spacing: 10) {
            Image(systemName: message.kind == .success ? "checkmark.circle.fill" : message.kind == .error ? "exclamationmark.circle.fill" : "info.circle")
                .foregroundStyle(message.kind == .error ? Color.orange : Color.secondary)
                .accessibilityHidden(true)
            Text(message.text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Button("关闭提示", systemImage: "xmark") { center.dismiss() }
                .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("关闭提示")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08)) }
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        .frame(maxWidth: 420)
    }
}
