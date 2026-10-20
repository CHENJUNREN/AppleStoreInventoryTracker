import SwiftUI

struct ProductInventoryHeader: View {
    let inventory: ProductInventory
    var title: String? = nil
    var summary: String? = nil
    var highlightedAvailability: String? = nil
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
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(title ?? inventory.productName)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if summary == nil {
                    Text("(\(inventory.availableStores.count))")
                        .foregroundStyle(inventory.availableStores.isEmpty ? .red : .green)
                        .fixedSize()
                    }
                }
                .font(.subheadline.weight(.semibold))

                Group {
                    if let highlightedAvailability {
                        Text("\(Text(summary ?? "").foregroundStyle(.secondary)) · \(Text(Image(systemName: "checkmark.circle.fill")).foregroundStyle(.green)) \(Text(highlightedAvailability).foregroundStyle(.green).fontWeight(.semibold))")
                    } else {
                        Text(summary ?? inventory.availabilitySummary).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .task(id: inventory.id) {
            guard let data = await ProductImageLoader.shared.imageData(for: inventory.id), !Task.isCancelled else { return }
            productImage = NSImage(data: data)
        }
    }
}
