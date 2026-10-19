import Foundation
import UserNotifications

typealias PushNotificationSettings = (isAppNotificationOn: Bool, isBarkNotificationOn: Bool, barkPushUrl: String)

@MainActor
protocol InventoryNotifying {
    func requestAuthorization()
    func send(_ inventories: [ProductInventory], settings: PushNotificationSettings) async
    func cancel()
}

@MainActor
final class InventoryNotifier: InventoryNotifying {
    private var pendingNotifications: [String: Date] = [:]
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, error in
            if error != nil { print("[Inventory] 无法申请 App 通知权限") }
        }
    }

    func cancel() {
        guard !pendingNotifications.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: Array(pendingNotifications.keys))
        pendingNotifications.removeAll()
    }

    func send(_ inventories: [ProductInventory], settings: PushNotificationSettings) async {
        guard settings.isAppNotificationOn || settings.isBarkNotificationOn else { return }
        pendingNotifications = pendingNotifications.filter { $0.value > Date() }
        for inventory in inventories {
            guard !Task.isCancelled else { return }
            let available = inventory.stores.filter(\.isProductAvailable)
            guard let first = available.first else { continue }
            let title = first.productName + "(\(available.count))‼️"
            let body = available.map(\.storeName).joined(separator: ", ")
            if settings.isAppNotificationOn {
                let center = UNUserNotificationCenter.current()
                let permissions = await center.notificationSettings()
                guard !Task.isCancelled else { return }
                if permissions.authorizationStatus == .authorized, permissions.alertSetting == .enabled {
                    let content = UNMutableNotificationContent()
                    content.title = title
                    content.body = body
                    let id = UUID().uuidString
                    pendingNotifications[id] = Date().addingTimeInterval(2)
                    let request = UNNotificationRequest(identifier: id, content: content,
                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.3, repeats: false))
                    do { try await center.add(request) }
                    catch { print("[Inventory] App 通知发送失败") }
                    if Task.isCancelled {
                        center.removePendingNotificationRequests(withIdentifiers: [id])
                        pendingNotifications.removeValue(forKey: id)
                        return
                    }
                }
            }
            guard !Task.isCancelled else { return }
            if settings.isBarkNotificationOn {
                guard let url = Self.barkURL(base: settings.barkPushUrl, title: title, body: body) else {
                    print("[Inventory] Bark URL 无效")
                    continue
                }
                do {
                    let (_, response) = try await session.data(from: url)
                    guard !Task.isCancelled else { return }
                    if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
                        print("[Inventory] Bark 请求失败（HTTP \(response.statusCode)）")
                    }
                } catch {
                    if !Task.isCancelled { print("[Inventory] Bark 请求失败") }
                }
            }
        }
    }

    static func barkURL(base: String, title: String, body: String) -> URL? {
        guard var components = URLComponents(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty else { return nil }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let title = title.addingPercentEncoding(withAllowedCharacters: unreserved),
              let body = body.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        let path = components.percentEncodedPath
        components.percentEncodedPath = path + (path.hasSuffix("/") ? "" : "/") + title + "/" + body
        components.fragment = nil
        return components.url
    }
}
