//
//  Inventory.swift
//  AppleStoreInventoryTracker
//
//  Created by Chenjun Ren on 2023/10/17.
//

import Foundation

struct StoreInventoryInfo: Identifiable, Hashable {
    let productId: String
    let storeNumber: String
    var id: String { "\(productId):\(storeNumber)" }
    let storeName: String
    let storeImageUrl: String
    let productName: String
    let isProductAvailable: Bool

    init(storeName: String, storeImageUrl: String, productName: String, isProductAvailable: Bool,
         productId: String = "preview", storeNumber: String? = nil) {
        self.productId = productId
        self.storeNumber = storeNumber ?? storeName
        self.storeName = storeName
        self.storeImageUrl = storeImageUrl
        self.productName = productName
        self.isProductAvailable = isProductAvailable
    }
}

struct ProductInventory: Identifiable {
    let id: String
    let stores: [StoreInventoryInfo]
}

// Only the pickup response is modeled; delivery and reservation flows are outside this app.
struct PickupAPIModel: Decodable {
    let head: Head?
    let body: Body
    struct Head: Decodable {
        let status: Int?
        enum CodingKeys: String, CodingKey { case status }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.status), try !container.decodeNil(forKey: .status) else {
                status = nil
                return
            }
            if let number = try? container.decode(Int.self, forKey: .status) {
                status = number
            } else {
                let text = try container.decode(String.self, forKey: .status)
                guard let number = Int(text) else {
                    throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "Invalid pickup status")
                }
                status = number
            }
        }
    }
    struct Body: Decodable { let stores: [Store] }
    struct Store: Decodable {
        let storeNumber: String?
        let storeName: String
        let storeImageUrl: String?
        let partsAvailability: [String: Part]
    }
    struct Part: Decodable {
        let partNumber: String?
        let pickupDisplay: String?
        let storePickEligible: Bool?
        let messageTypes: MessageTypes?
    }
    struct MessageTypes: Decodable { let regular: Regular? }
    struct Regular: Decodable { let storePickupProductTitle: String? }
}
