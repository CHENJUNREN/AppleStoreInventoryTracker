//
//  ContentViewModel.swift
//  AppleStoreInventoryTracker
//
//  Created by Chenjun Ren on 2023/10/19.
//

import Foundation
import Observation

@MainActor
@Observable
final class ContentViewModel {
    private(set) var isTracking = false
    private(set) var isQuerying = false
    private(set) var hasStarted = false
    private(set) var hasCompletedRequest = false
    private(set) var pollingPhase: InventoryPollingPolicy.Phase = .regular
    private(set) var trackingCount = 0
    private(set) var inventoryInfos: [ProductInventory] = []
    private(set) var countdownRemaining = 0
    private(set) var countdown = 0
    var countdownText: String {
        let remaining = max(0, countdownRemaining)
        return String(format: "%02d:%02d", remaining / 60, remaining % 60)
    }
    var countdownLabel: String {
        if lastError != nil { return "查询失败，等待重试" }
        switch pollingPhase {
        case .regular: return "下次查询"
        case .accelerated: return "加速查询中 · 下次查询"
        case .observing: return "观察库存变化 · 下次查询"
        }
    }
    private(set) var lastError: String? {
        didSet { if let lastError, lastError != oldValue { onError?(lastError) } }
    }
    @ObservationIgnored var onActivity: ((String, TaskActivity.Kind) -> Void)?
    @ObservationIgnored var onError: ((String) -> Void)?
    private(set) var lastSuccessAt: Date?
    @ObservationIgnored var onResult: ((CachedScanResult) -> Void)?
    @ObservationIgnored private var resultLocation: String?
    @ObservationIgnored var configurationProvider: (() -> ScanDefaults)?

    @ObservationIgnored private let client: any InventoryFetching
    @ObservationIgnored private let notifier: any InventoryNotifying
    @ObservationIgnored private let clock: any TrackingClock
    @ObservationIgnored private let activity: any MonitoringActivityManaging
    @ObservationIgnored private var trackingTask: Task<Void, Never>?
    @ObservationIgnored private var runID: UUID?
    @ObservationIgnored private var notificationTask: Task<Void, Never>?

    init(client: (any InventoryFetching)? = nil, notifier: (any InventoryNotifying)? = nil,
         clock: (any TrackingClock)? = nil, activity: (any MonitoringActivityManaging)? = nil) {
        self.client = client ?? InventoryClient()
        self.notifier = notifier ?? InventoryNotifier()
        self.clock = clock ?? SystemTrackingClock()
        self.activity = activity ?? MonitoringActivity()
        if let notifier = self.notifier as? InventoryNotifier {
            notifier.onActivity = { [weak self] message, kind in self?.onActivity?(message, kind) }
        }
    }

    func restore(_ result: CachedScanResult) {
        guard !isTracking else { return }
        inventoryInfos = result.inventories
        lastSuccessAt = result.updatedAt
        resultLocation = result.location
    }

    func requestUNAuthorization() { notifier.requestAuthorization() }

    func startTracking(for productIds: String, location: String, countdown: Int,
                       pushNotificationSettings: PushNotificationSettings) {
        guard !isTracking else { return }
        var seen = Set<String>()
        let ids = productIds.components(separatedBy: CharacterSet(charactersIn: ",，"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        let location = location.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep duration arithmetic and progress values representable even for pasted integers.
        guard !ids.isEmpty, !location.isEmpty, countdown > 0, countdown <= Int(Int32.max) else {
            lastError = InventoryError.invalidInput.localizedDescription
            onActivity?(InventoryError.invalidInput.localizedDescription, .error)
            print("[Inventory] \(lastError!)")
            return
        }
        let id = UUID()
        runID = id
        activity.begin()
        onActivity?("已开始监控，每 \(countdown) 秒查询", .information)
        isTracking = true
        hasStarted = true
        if resultLocation != location || Set(inventoryInfos.map(\.id)) != Set(ids) {
            inventoryInfos = []
            lastSuccessAt = nil
        }
        resultLocation = location
        trackingCount = 0
        lastError = nil
        self.countdown = countdown
        countdownRemaining = 0
        hasCompletedRequest = false
        pollingPhase = .regular
        trackingTask = Task { [weak self] in
            await self?.track(ids: ids, location: location, interval: countdown,
                              settings: pushNotificationSettings, run: id)
        }
    }

    func stopTracking(preservingResults: Bool = false) {
        if isTracking { onActivity?("已停止监控", .information) }
        runID = nil
        isTracking = false
        isQuerying = false
        activity.end()
        trackingTask?.cancel()
        trackingTask = nil
        notificationTask?.cancel()
        notificationTask = nil
        notifier.cancel()
        if !preservingResults {
            trackingCount = 0
            inventoryInfos = []
            lastSuccessAt = nil
        }
        countdown = 0
        countdownRemaining = 0
        hasCompletedRequest = false
        pollingPhase = .regular
        lastError = nil
    }

    private func isCurrent(_ id: UUID) -> Bool {
        isTracking && runID == id && !Task.isCancelled
    }

    private func track(ids: [String], location: String, interval: Int,
                       settings: PushNotificationSettings, run: UUID) async {
        var previous = Dictionary(uniqueKeysWithValues: inventoryInfos.map { ($0.id, $0) })
        var failures = 0
        var previousLocation = location
        var polling = InventoryPollingPolicy()
        while isCurrent(run) {
            let configuration = configurationProvider?()
            let location = configuration?.region.location ?? location
            let interval = configuration?.interval ?? interval
            let settings: PushNotificationSettings = configuration.map { ($0.appNotification, $0.barkNotification, $0.barkURL) } ?? settings
            if location != previousLocation {
                previous = [:]
                inventoryInfos = []
                lastSuccessAt = nil
                polling = InventoryPollingPolicy()
                failures = 0
                previousLocation = location
                resultLocation = location
            }
            isQuerying = true
            let started = clock.now
            var fresh: [ProductInventory] = []
            var errors: [String] = []
            var retryAfter = 0
            do {
                let result = try await client.fetchPickupInventory(for: ids, location: location)
                guard isCurrent(run) else { return }
                fresh = result.inventories
                for inventory in fresh { previous[inventory.id] = inventory }
                retryAfter = result.failures.values.compactMap(\.retryAfter).max() ?? 0
                errors = result.failures.keys.sorted().map { "\($0): \(result.failures[$0]!.localizedDescription)" }
            } catch {
                guard isCurrent(run) else { return }
                let failure = error as? InventoryError ?? .invalidResponse
                errors = [failure.localizedDescription]
                retryAfter = failure.retryAfter ?? 0
            }
            guard isCurrent(run) else { return }
            inventoryInfos = previous.values.filter { !$0.stores.isEmpty }.sorted {
                let lhs = $0.stores.first?.productName ?? $0.id
                let rhs = $1.stores.first?.productName ?? $1.id
                return lhs == rhs ? $0.id < $1.id : lhs < rhs
            }
            isQuerying = false
            lastError = errors.isEmpty ? nil : errors.joined(separator: "；")
            if let lastError { print("[Inventory] \(lastError)") }
            if errors.isEmpty {
                lastSuccessAt = Date()
                resultLocation = location
                onResult?(CachedScanResult(inventories: inventoryInfos, location: location, updatedAt: lastSuccessAt!))
                trackingCount += 1
                failures = 0
            } else {
                failures = min(failures + 1, 9)
            }
            polling.update(hasStock: fresh.contains { !$0.availableStores.isEmpty },
                           succeeded: errors.isEmpty, now: clock.now)
            pollingPhase = polling.phase
            // A slow push must not block polling or accumulate queued notification tasks.
            if notificationTask == nil {
                notificationTask = Task { [weak self, notifier, fresh] in
                    await notifier.send(fresh, settings: settings)
                    guard let self, self.runID == run else { return }
                    self.notificationTask = nil
                }
            }
            let pollingInterval = polling.interval(base: interval)
            let delay = errors.isEmpty ? pollingInterval
                : InventoryRetryPolicy.delay(interval: interval, failures: failures, retryAfter: retryAfter)
            let deadline = errors.isEmpty ? max(started + Double(pollingInterval), clock.now) : clock.now + Double(delay)
            if !errors.isEmpty { onActivity?("\(lastError ?? "查询暂时失败")，\(delay) 秒后重试", .warning) }
            countdown = delay
            hasCompletedRequest = true
            do {
                while isCurrent(run) {
                    let remaining = max(0, deadline - clock.now)
                    countdownRemaining = Int(ceil(remaining))
                    if remaining <= 0 { break }
                    try await clock.sleep(seconds: min(1, remaining))
                }
            } catch { return }
        }
    }
}
