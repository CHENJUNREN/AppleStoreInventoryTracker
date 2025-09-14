//
//  ContentViewModel.swift
//  AppleStoreInventoryTracker
//
//  Created by Chenjun Ren on 2023/10/19.
//

import Foundation
import Observation
import UserNotifications

typealias PushNotificationSettings = (isAppNotificationOn: Bool, isBarkNotificationOn: Bool, barkPushUrl: String)

@Observable
class ContentViewModel {
    
    private(set) var isTracking = false
    private(set) var trackingCount = 0
    private(set) var inventoryInfos: [[StoreInventoryInfo]] = []
    
    private(set) var countdownRemaining = 0
    private(set) var countdown = 0
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
    
    func sendNotificationIfNeeded(settings: PushNotificationSettings) {
        guard isTracking &&
                (settings.isAppNotificationOn || settings.isBarkNotificationOn)
        else {
            return
        }
        
        for inventoryInfo in inventoryInfos {
            guard inventoryInfo.filter(\.isProductAvailable).count > 0 else {
                continue
            }
//            let title = "附近 \(inventoryInfo.filter(\.isProductAvailable).count) 家 Apple Store 有现货‼️"
//            let body = inventoryInfo.first!.productName
            let title = inventoryInfo.first!.productName + "(\(inventoryInfo.filter(\.isProductAvailable).count))‼️"
            let body = inventoryInfo.filter(\.isProductAvailable).map(\.storeName).joined(separator: ", ")
            // App 通知推送
            if settings.isAppNotificationOn {
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    guard settings.authorizationStatus == .authorized,
                          settings.alertSetting == .enabled
                    else {
                        return
                    }
                    let content = UNMutableNotificationContent()
                    content.title = title
                    content.body = body
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.3, repeats: false)
                    let request = UNNotificationRequest(
                        identifier: UUID().uuidString,
                        content: content,
                        trigger: trigger
                    )
                    UNUserNotificationCenter.current().add(request)
                }
            }
            // Bark 推送
            if settings.isBarkNotificationOn {
                let barkPushUrl = settings.barkPushUrl
                let urlString = barkPushUrl.hasSuffix("/") ? barkPushUrl : barkPushUrl + "/"
                if let url = URL(string: urlString + "\(title)/\(body)") {
                    URLSession.shared.dataTask(with: url).resume()
                }
            }
        }
    }
    
    @MainActor
    func startTracking(
        for productIds: String,
        location: String,
        countdown: Int,
        pushNotificationSettings: PushNotificationSettings
    ) {
        isTracking = true
        self.countdown = countdown
        timer = .init(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            self.countdownRemaining -= 1
            guard self.countdownRemaining < 0 else {
                return
            }
            Task { @MainActor in
                let ids = productIds
                    .components(separatedBy: ",")
                    .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                    .filter({ !$0.isEmpty })
                
                self.inventoryInfos = await withTaskGroup(
                    of: [StoreInventoryInfo].self,
                    returning: [[StoreInventoryInfo]].self
                ) { taskGroup in
                    for id in ids {
                        taskGroup.addTask {
                            await self.fetchStoreInventoryInfo(for: id, location: location)
                        }
                    }
                    var result = [[StoreInventoryInfo]]()
                    for await task in taskGroup {
                        result.append(task)
                    }
                    return result.filter({ !$0.isEmpty }).sorted(by: { $0.first!.productName < $1.first!.productName })
                }
                self.trackingCount += 1
                self.sendNotificationIfNeeded(settings: pushNotificationSettings)
            }
            self.countdownRemaining = self.countdown
        }
        RunLoop.main.add(timer!, forMode: .common)
        timer?.fire()
    }
    
    @MainActor
    func stopTracking() {
        isTracking = false
        trackingCount = 0
        inventoryInfos = []
        timer?.invalidate()
        timer = nil
        countdown = 0
        countdownRemaining = 0
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
            return result.sorted(by: { $0.storeName > $1.storeName })
        } else {
            return []
        }
    }
    
}
