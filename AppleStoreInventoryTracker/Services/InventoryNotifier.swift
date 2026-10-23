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
    var onActivity: ((String, TaskActivity.Kind) -> Void)?
    private var pendingNotifications: [String: Date] = [:]
    private var notificationPolicy = InventoryNotificationPolicy()
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
        notificationPolicy = InventoryNotificationPolicy()
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
            guard notificationPolicy.shouldNotify(inventory, now: ProcessInfo.processInfo.systemUptime),
                  let first = available.first else { continue }
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
                    do { try await center.add(request); if !Task.isCancelled { onActivity?("系统通知已发送", .information) } }
                    catch { onActivity?("系统通知发送失败", .error) }
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
                        onActivity?("Bark 通知发送失败", .error)
                    } else if response is HTTPURLResponse {
                        onActivity?("Bark 通知已发送", .information)
                    }
                } catch {
                    if !Task.isCancelled { onActivity?("Bark 通知发送失败", .error) }
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
