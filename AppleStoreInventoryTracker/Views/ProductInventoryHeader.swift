import SwiftUI

struct ProductInventoryHeader<Summary: View>: View {
    let product: String
    let title: String
    @ViewBuilder var summary: () -> Summary
    @State private var productImage: NSImage?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if let productImage {
                    Image(nsImage: productImage).resizable().interpolation(.high).scaledToFit()
                } else {
                    Image(systemName: "shippingbox")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 52, height: 52)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                summary()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .task(id: product) {
            productImage = nil
            guard let data = await ProductImageLoader.shared.imageData(for: product), !Task.isCancelled else { return }
            productImage = NSImage(data: data)
        }
    }
}
