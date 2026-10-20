//
//  Inventory.swift
//  AppleStoreInventoryTracker
//
//  Created by Chenjun Ren on 2023/10/17.
//

import Foundation

struct StoreInventoryInfo: Identifiable, Hashable, Codable {
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

struct ProductInventory: Identifiable, Codable {
    let id: String
    let stores: [StoreInventoryInfo]
}

struct CachedScanResult: Codable {
    let inventories: [ProductInventory]
    let location: String
    let updatedAt: Date
}
