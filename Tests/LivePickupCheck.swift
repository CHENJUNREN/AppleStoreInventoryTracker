import Foundation

/// Explicit opt-in smoke test: queries Apple once through the app's actual client.
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
        }
        print("PASS: real native batch pickup request; no browser/session or notifications")
    }
}
