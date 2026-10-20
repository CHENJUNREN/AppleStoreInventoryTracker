import Foundation

struct InventoryNotificationPolicy {
    private var lastAlerts: [String: (stores: Set<String>, time: TimeInterval)] = [:]

    mutating func shouldNotify(_ inventory: ProductInventory, now: TimeInterval) -> Bool {
        let stores = Set(inventory.availableStores.map(\.storeNumber))
        guard !stores.isEmpty else {
            lastAlerts.removeValue(forKey: inventory.id)
            return false
        }
        if let previous = lastAlerts[inventory.id],
           stores.isSubset(of: previous.stores), now - previous.time < 60 {
            lastAlerts[inventory.id] = (stores, previous.time)
            return false
        }
        lastAlerts[inventory.id] = (stores, now)
        return true
    }
}
