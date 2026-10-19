//
//  ContentViewModel.swift
//  AppleStoreInventoryTracker
//
//  Created by Chenjun Ren on 2023/10/19.
//

import Foundation
import Observation

@MainActor
protocol TrackingClock {
    var now: TimeInterval { get }
    func sleep(seconds: TimeInterval) async throws
}

@MainActor
struct SystemTrackingClock: TrackingClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

@MainActor
@Observable
final class ContentViewModel {
    private(set) var isTracking = false
    private(set) var trackingCount = 0
    private(set) var inventoryInfos: [ProductInventory] = []
    private(set) var countdownRemaining = 0
    private(set) var countdown = 0
    var countdownText: String {
        let remaining = max(0, countdownRemaining)
        return String(format: "%02d:%02d", remaining / 60, remaining % 60)
    }
    private(set) var lastError: String?

    @ObservationIgnored private let client: any InventoryFetching
    @ObservationIgnored private let notifier: any InventoryNotifying
    @ObservationIgnored private let clock: any TrackingClock
    @ObservationIgnored private var trackingTask: Task<Void, Never>?
    @ObservationIgnored private var runID: UUID?

    init(client: (any InventoryFetching)? = nil, notifier: (any InventoryNotifying)? = nil,
         clock: (any TrackingClock)? = nil) {
        self.client = client ?? InventoryClient()
        self.notifier = notifier ?? InventoryNotifier()
        self.clock = clock ?? SystemTrackingClock()
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
            print("[Inventory] \(lastError!)")
            return
        }
        let id = UUID()
        runID = id
        isTracking = true
        trackingCount = 0
        inventoryInfos = []
        lastError = nil
        self.countdown = countdown
        countdownRemaining = 0
        trackingTask = Task { [weak self] in
            await self?.track(ids: ids, location: location, interval: countdown,
                              settings: pushNotificationSettings, run: id)
        }
    }

    func stopTracking() {
        runID = nil
        isTracking = false
        trackingTask?.cancel()
        trackingTask = nil
        notifier.cancel()
        trackingCount = 0
        inventoryInfos = []
        countdown = 0
        countdownRemaining = 0
        lastError = nil
    }

    private func isCurrent(_ id: UUID) -> Bool {
        isTracking && runID == id && !Task.isCancelled
    }

    private func track(ids: [String], location: String, interval: Int,
                       settings: PushNotificationSettings, run: UUID) async {
        var previous: [String: ProductInventory] = [:]
        var failures = 0
        while isCurrent(run) {
            let started = clock.now
            var fresh: [ProductInventory] = []
            var errors: [String] = []
            var retryAfter = 0
            do {
                let result = try await client.fetchPickupInventory(for: ids, location: location)
                guard isCurrent(run) else { return }
                fresh = result.inventories
                for inventory in fresh { previous[inventory.id] = inventory }
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
            lastError = errors.isEmpty ? nil : errors.joined(separator: "；")
            if let lastError { print("[Inventory] \(lastError)") }
            if errors.isEmpty {
                trackingCount += 1
                failures = 0
            } else {
                failures = min(failures + 1, 9)
            }
            // Only this round's confirmed results may trigger notifications.
            await notifier.send(fresh, settings: settings)
            guard isCurrent(run) else { return }
            let delay = errors.isEmpty ? interval
                : InventoryRetryPolicy.delay(interval: interval, failures: failures, retryAfter: retryAfter)
            let deadline = errors.isEmpty ? max(started + Double(interval), clock.now) : clock.now + Double(delay)
            countdown = delay
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
