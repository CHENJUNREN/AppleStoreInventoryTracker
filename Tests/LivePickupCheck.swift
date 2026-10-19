import Foundation
import AppKit

/// Explicit opt-in smoke test: one batch pickup query plus product-page/image checks.
/// No notification service, UI, browser, cookies or user credentials are involved.
@main
struct LivePickupCheck {
    @MainActor
    static func main() async {
        do { try await run() }
        catch {
            print("FAIL: live pickup query: \(error.localizedDescription)")
            exit(1)
        }
    }

    @MainActor
    private static func run() async throws {
        let products = ["MJTD4CH/A", "MJYC4CH/A"]
        let result = try await InventoryClient().fetchPickupInventory(for: products, location: "上海 上海 长宁区")
        guard result.failures.isEmpty, result.inventories.count == products.count,
              result.inventories.allSatisfy({ !$0.stores.isEmpty }) else {
            throw InventoryError.invalidInventory
        }
        for inventory in result.inventories {
            print("\(inventory.id): stores=\(inventory.stores.count), pickupAvailable=\(inventory.stores.filter(\.isProductAvailable).count)")
            guard let imageURL = await ProductImageLoader.shared.imageURL(for: inventory.id) else {
                throw InventoryError.invalidResponse
            }
            let (imageData, response) = try await URLSession.shared.data(from: imageURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let bitmap = NSBitmapImageRep(data: imageData), bitmap.pixelsWide == 192, bitmap.pixelsHigh == 192 else {
                throw InventoryError.invalidResponse
            }
            print("PASS: \(inventory.id) purchase-page redirect and 192×192 product thumbnail")
        }
        print("PASS: real native batch pickup request; no browser/session or notifications")
    }
}
