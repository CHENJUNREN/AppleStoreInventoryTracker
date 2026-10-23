import Foundation
import Observation

@MainActor
@Observable
final class TaskStore {
    private struct Snapshot: Codable {
        var defaults: ScanDefaults
        var tasks: [ScanTask]
        var results: [String: CachedScanResult]?
        var histories: [String: TaskActivityHistory]?
    }
    let toast = ToastCenter()
    let purchaseAssistant = PurchaseAssistant()
    private(set) var defaults = ScanDefaults()
    private(set) var tasks: [ScanTask] = []
    private(set) var histories: [String: TaskActivityHistory] = [:]
    private(set) var storageError: String?
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let client = ScheduledInventoryClient()
    @ObservationIgnored private var results: [String: CachedScanResult] = [:]
    @ObservationIgnored private var runners: [UUID: ContentViewModel] = [:]
    @ObservationIgnored private var pendingHistorySave: Task<Void, Never>?
    private static let storageKey = "desktopScanTasks.v1"

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        purchaseAssistant.onFeedback = { [weak self] text, isError in
            self?.toast.show(text, kind: isError ? .error : .information)
        }
        purchaseAssistant.onActivity = { [weak self] id, message, kind in
            self?.record(message, kind: kind, for: id)
        }
        if let data = preferences.data(forKey: Self.storageKey) {
            do {
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
                defaults = snapshot.defaults
                tasks = snapshot.tasks
                results = snapshot.results ?? [:]
                histories = snapshot.histories ?? [:]
            } catch {
                storageError = "无法读取已保存的任务。原始数据已保留，请先备份再重试。"
            }
        } else {
            defaults.region = ScanRegion(province: preferences.string(forKey: "province") ?? "重庆",
                                         city: preferences.string(forKey: "city") ?? "重庆",
                                         district: preferences.string(forKey: "district") ?? "九龙坡区")
            let interval = preferences.integer(forKey: "countdown")
            defaults.interval = interval > 0 ? interval : 60
            defaults.appNotification = preferences.object(forKey: "isAppNotificationOn") as? Bool ?? true
            defaults.barkURL = preferences.string(forKey: "barkPushUrl") ?? ""
            defaults.barkNotification = (preferences.object(forKey: "isBarkNotificationOn") as? Bool ?? true) && !defaults.barkURL.isEmpty
            var seen = Set<String>()
            tasks = (preferences.string(forKey: "partNumber") ?? "")
                .components(separatedBy: CharacterSet(charactersIn: ",，"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
                .map { ScanTask(product: $0) }
        }
        if storageError == nil {
            tasks = tasks.map { $0.frozen(using: defaults) }
            persist()
        }
    }

    var runningCount: Int { tasks.filter { runner(for: $0.id).isTracking }.count }

    func runner(for id: UUID) -> ContentViewModel {
        if let runner = runners[id] { return runner }
        let runner = ContentViewModel(client: client)
        if let task = tasks.first(where: { $0.id == id }), let result = results[id.uuidString],
           result.location == task.resolved(using: defaults).region.location,
           result.inventories.allSatisfy({ $0.id == task.normalizedProduct }) {
            runner.restore(result)
        }
        runner.onActivity = { [weak self] message, kind in
            self?.record(message, kind: kind, for: id)
        }
        runner.onResult = { [weak self] result in
            guard let self, self.tasks.contains(where: { $0.id == id }) else { return }
            let previous = self.results[id.uuidString]?.inventories.flatMap(\.stores) ?? []
            let current = result.inventories.flatMap(\.stores)
            let old = Dictionary(previous.map { ($0.id, $0.isProductAvailable) }, uniquingKeysWith: { _, new in new })
            let changed = current.filter { old[$0.id] != $0.isProductAvailable }
            if !changed.isEmpty {
                let message = changed.map { shop in
                    let status = shop.isProductAvailable
                        ? (old[shop.id] == false ? "恢复有货" : "有货") : "暂无现货"
                    return shop.storeName.trimmingCharacters(in: .whitespaces) + status
                }.joined(separator: " · ")
                self.record(message, kind: changed.contains(where: \.isProductAvailable) ? .stock : .information, for: id)
            } else {
                let availableCount = current.filter(\.isProductAvailable).count
                let message = availableCount == 0 ? "查询完成 · 暂无现货" : "查询完成 · \(availableCount) 家门店可取货"
                self.record(message, key: "inventory", for: id)
            }
            self.results[id.uuidString] = result
            self.persist()
            if let task = self.tasks.first(where: { $0.id == id }), self.runner(for: id).isTracking {
                self.purchaseAssistant.consider(task: task, result: result)
            }
        }
        runners[id] = runner
        return runner
    }

    func validationError(for task: ScanTask) -> String? {
        guard !task.normalizedProduct.isEmpty else { return "请输入产品型号。" }
        let effective = task.resolved(using: defaults)
        guard effective.isValid else { return "请填写完整地区，并输入有效的查询间隔。" }
        guard !effective.barkNotification || InventoryNotifier.barkURL(base: effective.barkURL, title: "test", body: "test") != nil else { return "请填写有效的 Bark 地址，或关闭 Bark 推送。" }
        return nil
    }

    func save(_ task: ScanTask, start: Bool) {
        guard storageError == nil, validationError(for: task) == nil else { return }
        var task = task.frozen(using: defaults)
        task.product = task.normalizedProduct
        let wasRunning = runner(for: task.id).isTracking
        if wasRunning { runner(for: task.id).stopTracking(preservingResults: true) }
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            let old = tasks[index]
            if old.product != task.product || old.resolved(using: defaults).region != task.resolved(using: defaults).region {
                runner(for: task.id).stopTracking()
                results.removeValue(forKey: task.id.uuidString)
            }
            tasks[index] = task
        }
        else { tasks.append(task) }
        persist()
        if start || wasRunning { self.start(task) }
    }

    func start(_ task: ScanTask) {
        guard validationError(for: task) == nil else { return }
        let settings = task.resolved(using: defaults)
        let runner = runner(for: task.id)
        if settings.appNotification { runner.requestUNAuthorization() }
        runner.configurationProvider = { settings }
        runner.startTracking(for: task.product, location: settings.region.location, countdown: settings.interval,
                             pushNotificationSettings: (settings.appNotification, settings.barkNotification, settings.barkURL))
    }

    func canEnablePurchase(_ settings: TaskPurchaseSettings?) -> Bool {
        guard let settings else { return false }
        return !settings.stores.isEmpty && purchaseAssistant.profile.validationError == nil && purchaseAssistant.ready
    }

    func setPurchase(_ settings: TaskPurchaseSettings, for id: UUID) {
        guard storageError == nil, let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard !settings.enabled || canEnablePurchase(settings) else { return }
        if settings.enabled && tasks[index].purchase?.enabled != true {
            purchaseAssistant.reset(id)
        }
        tasks[index].purchase = settings
        if !settings.enabled { purchaseAssistant.disable(id) }
        persist()
    }

    func delete(_ task: ScanTask) {
        purchaseAssistant.reset(task.id)
        runner(for: task.id).stopTracking()
        runners.removeValue(forKey: task.id)
        results.removeValue(forKey: task.id.uuidString)
        tasks.removeAll { $0.id == task.id }
        histories.removeValue(forKey: task.id.uuidString)
        persist()
    }

    func saveDefaults(_ value: ScanDefaults) {
        guard value.isValid, storageError == nil else { return }
        defaults = value
        persist()
    }

    func stopAll() {
        for runner in runners.values { runner.stopTracking(preservingResults: true) }
        purchaseAssistant.shutdown()
        persist()
    }

    private func record(_ message: String, kind: TaskActivity.Kind = .information, key: String? = nil, for id: UUID) {
        guard tasks.contains(where: { $0.id == id }) else { return }
        histories[id.uuidString, default: TaskActivityHistory()].record(message, kind: kind, key: key)
        pendingHistorySave?.cancel()
        pendingHistorySave = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.persist()
        }
    }

    private func persist() {
        pendingHistorySave?.cancel()
        pendingHistorySave = nil
        guard storageError == nil else { return }
        do { preferences.set(try JSONEncoder().encode(Snapshot(defaults: defaults, tasks: tasks, results: results, histories: histories)), forKey: Self.storageKey) }
        catch { storageError = "任务保存失败：\(error.localizedDescription)" }
    }
}

/// A shared request budget prevents many independently timed tasks from flooding the service.
@MainActor
final class ScheduledInventoryClient: InventoryFetching {
    private let client: any InventoryFetching
    private let limit: Int
    private var active = 0
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []

    init(client: (any InventoryFetching)? = nil, limit: Int = 3) {
        self.client = client ?? InventoryClient()
        self.limit = max(1, limit)
    }

    func fetchPickupInventory(for productIds: [String], location: String) async throws -> InventoryBatchResult {
        try Task.checkCancellation()
        if active >= limit {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiting.append((id, continuation))
                }
            } onCancel: {
                Task { @MainActor in
                    if let index = self.waiting.firstIndex(where: { $0.0 == id }) {
                        self.waiting.remove(at: index).1.resume(throwing: CancellationError())
                    }
                }
            }
        } else { active += 1 }
        defer {
            if waiting.isEmpty { active -= 1 }
            else { waiting.removeFirst().1.resume() }
        }
        try Task.checkCancellation()
        return try await client.fetchPickupInventory(for: productIds, location: location)
    }
}
