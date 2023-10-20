//
//  Inventory.swift
//  AppleStoreInventoryTracker
//
//  Created by Chenjun Ren on 2023/10/17.
//

import Foundation

struct StoreInventoryInfo: Identifiable {
    let id: UUID = .init()
    let storeName: String
    let storeImageUrl: String
    let productName: String
    let isProductAvailable: Bool
}

struct InventoryAPIModel: Codable {
    let body: Body
    
    struct Body: Codable {
        let content: Content
        
        struct Content: Codable {
            let pickupMessage: PickupMessage
            
            struct PickupMessage: Codable {
                let stores: [Store]
                
                struct Store: Codable {
                    let storeName: String
                    let storeImageUrl: String
                    let partsAvailability: [String: InventoryInfo]
                    
                    struct InventoryInfo: Codable {
                        let pickupDisplay: String
                        let messageTypes: MessageTypes
                        
                        struct MessageTypes: Codable {
                            let compact: Compact
                            
                            struct Compact: Codable {
                                let storePickupProductTitle: String
                            }
                        }
                    }
                }
            }
        }
    }
}
