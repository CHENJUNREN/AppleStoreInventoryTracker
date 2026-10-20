import SwiftUI

struct ProductInventoryHeader: View {
    let inventory: ProductInventory
    @State private var imageURL: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AsyncImage(url: imageURL) { phase in
                if let image = phase.image {
                    image.resizable().interpolation(.high).scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.gray)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 64, height: 64)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(inventory.productName)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("(\(inventory.availableStores.count))")
                        .foregroundStyle(inventory.availableStores.isEmpty ? .red : .green)
                        .fixedSize()
                }
                .font(.subheadline.weight(.semibold))

                Text(inventory.availabilitySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .task(id: inventory.id) {
            imageURL = nil
            let url = await ProductImageLoader.shared.imageURL(for: inventory.id)
            guard !Task.isCancelled else { return }
            imageURL = url
        }
    }
}
