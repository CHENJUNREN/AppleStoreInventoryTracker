import Foundation

extension ProductInventory {
    var productName: String { stores.first?.productName ?? id }
    var availableStores: [StoreInventoryInfo] { stores.filter(\.isProductAvailable) }
    var availabilitySummary: String {
        let names = availableStores.map(\.storeName)
        return names.isEmpty ? "当前无门店可供取货" : names.joined(separator: ", ")
    }
    var purchaseURL: URL? { AppleProductPage.purchaseURL(for: id) }
}
