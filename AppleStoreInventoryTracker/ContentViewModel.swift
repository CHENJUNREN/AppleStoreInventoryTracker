//
//  ContentViewModel.swift
//  AppleStoreInventoryTracker
//
//  Created by Chenjun Ren on 2023/10/19.
//

import Foundation
import Observation
import UserNotifications

@Observable
class ContentViewModel {
    
    private(set) var isTracking = false
    private(set) var trackingCount = 0
    private(set) var inventoryInfo: [StoreInventoryInfo] = []
    
    @ObservationIgnored private var timer: Timer?
    
    func requestUNAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if granted {
                print("All set!")
            } else if let error = error {
                print(error.localizedDescription)
            }
        }
    }
    
    func sendUserNotificationIfNeeded() {
        guard isTracking,
              inventoryInfo.filter({ $0.isProductAvailable }).count > 0 
        else {
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized,
                  settings.alertSetting == .enabled else {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "附近 \(self.inventoryInfo.filter({ $0.isProductAvailable }).count) 家 Apple Store 有现货‼️"
            content.body = "\(self.inventoryInfo.first?.productName ?? "")"
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.3, repeats: false)
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: trigger
            )
            UNUserNotificationCenter.current().add(request)
        }
    }
    
    @MainActor
    func startTracking(for productId: String, location: String, frequency: Int) {
        isTracking = true
        timer = .init(timeInterval: TimeInterval(frequency), repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            Task { @MainActor in
                self.inventoryInfo = await self.fetchStoreInventoryInfo(for: productId, location: location)
                self.trackingCount += 1
                self.sendUserNotificationIfNeeded()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
        timer?.fire()
    }
    
    @MainActor
    func stopTracking() {
        isTracking = false
        trackingCount = 0
        inventoryInfo = []
        timer?.invalidate()
        timer = nil
    }

    func fetchStoreInventoryInfo(for productId: String, location: String) async -> [StoreInventoryInfo] {
        guard !productId.isEmpty, !location.isEmpty else {
            return []
        }
        let baseURL = "https://www.apple.com.cn/shop/fulfillment-messages?pl=true&mts.0=regular&mts.1=compact&parts.0=%@&location=%@"
        let requestURLString = String(format: baseURL, productId, location)
        guard let str = requestURLString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: str)
        else {
            return []
        }
        
        if let resp = try? await URLSession.shared.data(for: .init(url: url, cachePolicy: .reloadIgnoringLocalCacheData)) {
            guard let httpResponse = resp.1 as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let data = try? JSONDecoder().decode(InventoryAPIModel.self, from: resp.0)
            else {
                return []
            }
            var result: [StoreInventoryInfo] = []
            let stores = data.body.content.pickupMessage.stores
            stores.forEach { store in
                guard let inventoryInfo = store.partsAvailability[productId] else {
                    return
                }
                let info = StoreInventoryInfo(
                    storeName: store.storeName,
                    storeImageUrl: store.storeImageUrl,
                    productName: inventoryInfo.messageTypes.compact.storePickupProductTitle,
                    isProductAvailable: inventoryInfo.pickupDisplay == "available"
                )
                result.append(info)
            }
            return result
        } else {
            return []
        }
    }
    
}
