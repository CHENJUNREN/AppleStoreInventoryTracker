import Foundation

struct PreferredStore: Codable, Equatable, Identifiable {
    var id: String
    var name: String
}

struct TaskPurchaseSettings: Codable, Equatable {
    var enabled = false
    var stores: [PreferredStore] = []
    var appleCare = false

    func availableStores(in inventory: ProductInventory) -> [PreferredStore] {
        let available = Set(inventory.stores.filter(\.isProductAvailable).map(\.storeNumber))
        return stores.filter { available.contains($0.id) }
    }
}

struct PickupProfile: Codable, Equatable {
    enum Payment: String, Codable, CaseIterable {
        case alipay, wechat
        var title: String { self == .alipay ? "支付宝" : "微信" }
    }
    var lastName = ""
    var firstName = ""
    var emailAddress = ""
    var fullDaytimePhone = ""
    var nationalIdSelf = ""
    var payment = Payment.alipay

    var isEmpty: Bool { [lastName, firstName, emailAddress, fullDaytimePhone, nationalIdSelf].allSatisfy(\.isEmpty) }
    var validationError: String? {
        let values = [lastName, firstName, emailAddress, fullDaytimePhone, nationalIdSelf]
        guard values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return "请填写完整取货资料。" }
        guard values.allSatisfy({ $0.rangeOfCharacter(from: CharacterSet(charactersIn: "*•●")) == nil }) else { return "请填写真实取货资料，不要使用脱敏信息。" }
        guard emailAddress.contains("@"), emailAddress.split(separator: "@").count == 2 else { return "请检查邮箱地址。" }
        guard nationalIdSelf.count == 4 else { return "请填写身份证后四位。" }
        return nil
    }
}
