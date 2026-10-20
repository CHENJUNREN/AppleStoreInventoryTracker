import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

@MainActor
private func eventually(_ message: String, _ condition: () -> Bool) async {
    for _ in 0..<300 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    fatalError("TIMEOUT: \(message)")
}

private func stock(_ product: String, available: Bool = true) -> [StoreInventoryInfo] {
    [StoreInventoryInfo(storeName: "上海 / 店?#", storeImageUrl: "", productName: product,
                        isProductAvailable: available, productId: product, storeNumber: "R001")]
}

@MainActor
private final class RecordingActivity: MonitoringActivityManaging {
    var starts = 0
    var ends = 0
    func begin() { starts += 1 }
    func end() { ends += 1 }
}

@MainActor
private final class ManualClock: TrackingClock {
    var now: TimeInterval = 0
    private var sleepers: [UUID: (deadline: TimeInterval, continuation: CheckedContinuation<Void, Error>)] = [:]
    var waiting: Int { sleepers.count }

    func sleep(seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = (now + seconds, continuation)
            }
        } onCancel: {
            Task { @MainActor in self.sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }
        }
    }

    func advance(_ seconds: TimeInterval) {
        now += seconds
        let due = sleepers.filter { $0.value.deadline <= now }.map(\.key)
        for id in due { sleepers.removeValue(forKey: id)?.continuation.resume() }
    }
}

@MainActor
private final class ControlledClient: InventoryFetching {
    var calls: [[String]] = []
    var locations: [String] = []
    var active = 0
    var maxActive = 0
    private var pending: [Int: CheckedContinuation<InventoryBatchResult, Error>] = [:]

    func fetchPickupInventory(for productIds: [String], location: String) async throws -> InventoryBatchResult {
        let index = calls.count
        calls.append(productIds)
        locations.append(location)
        active += 1
        maxActive = max(maxActive, active)
        defer { active -= 1 }
        // Deliberately ignore cancellation to reproduce a late network completion.
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func complete(_ index: Int, _ result: Result<InventoryBatchResult, Error>) {
        guard let continuation = pending.removeValue(forKey: index) else { fatalError("Unknown request \(index)") }
        continuation.resume(with: result)
    }
}

@MainActor
private final class RecordingNotifier: InventoryNotifying {
    var rounds: [[ProductInventory]] = []
    var cancellations = 0
    var permissions = 0
    func requestAuthorization() { permissions += 1 }
    func send(_ inventories: [ProductInventory], settings: PushNotificationSettings) async { rounds.append(inventories) }
    func cancel() { cancellations += 1 }
}

@MainActor
private final class SlowNotifier: InventoryNotifying {
    var calls = 0
    private var pending: CheckedContinuation<Void, Never>?
    func requestAuthorization() {}
    func send(_ inventories: [ProductInventory], settings: PushNotificationSettings) async {
        calls += 1
        await withCheckedContinuation { pending = $0 }
    }
    func cancel() { pending?.resume(); pending = nil }
}

private struct StubResponse {
    var status = 200
    var type = "application/json"
    var body = ""
    var headers: [String: String] = [:]
}

private final class StubQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [StubResponse]
    private var recorded: [URLRequest] = []
    init(_ responses: [StubResponse]) { self.responses = responses }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    func next(_ request: URLRequest) -> StubResponse {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        guard !responses.isEmpty else { fatalError("Unexpected extra HTTP request") }
        return responses.removeFirst()
    }
}

private final class StubURLProtocol: URLProtocol {
    static var queue = StubQueue([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let result = Self.queue.next(request)
        var headers = result.headers
        headers["Content-Type"] = result.type
        let response = HTTPURLResponse(url: request.url!, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(result.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func batch(_ products: [String]) -> InventoryBatchResult {
    InventoryBatchResult(inventories: products.map { ProductInventory(id: $0, stores: stock($0)) }, failures: [:])
}
private func fixture(_ parts: [String: [String: Any]], headStatus: Int = 200) -> String {
    let object: [String: Any] = ["head": ["status": String(headStatus)], "body": ["stores": [
        ["storeNumber": "R001", "storeName": "上海 / 店?#", "partsAvailability": parts]
    ]]]
    return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
}
private func part(_ status: String, eligible: Bool = true) -> [String: Any] {
    ["pickupDisplay": status, "storePickEligible": eligible,
     "messageTypes": ["regular": ["storePickupProductTitle": "测试产品", "storeSelectionEnabled": true]]]
}

@main
struct RegressionTests {
    @MainActor private static let settings: PushNotificationSettings = (false, false, "")
    private static var passed = 0
    private static func pass(_ title: String) { passed += 1; print("PASS: \(title)") }

    @MainActor
    static func main() async throws {
        await restartPresentation()
        desktopPersistence()
        cachedResultsPersistence()
        try await cachedImageRelaunch()
        await independentDesktopTasks()
        await scheduledRequests()
        await powerLifecycle()
        pollingPolicies()
        await adaptiveSchedule()
        await slowNotifications()
        await lifecycle()
        await schedule()
        await failureRecovery()
        try urls()
        await presentation()
        try await client()
        print("\(passed) regression scenarios passed; no external requests or notifications sent.")
    }

    @MainActor
    private static func restartPresentation() async {
        let client = ControlledClient(), clock = ManualClock()
        let vm = ContentViewModel(client: client, notifier: RecordingNotifier(), clock: clock)
        vm.startTracking(for: "A", location: "上海", countdown: 60, pushNotificationSettings: settings)
        await eventually("presentation initial fetch") { client.calls.count == 1 }
        client.complete(0, .success(batch(["A"])))
        await eventually("presentation initial result") { clock.waiting == 1 }
        vm.stopTracking(preservingResults: true)
        vm.startTracking(for: "A", location: "上海", countdown: 60, pushNotificationSettings: settings)
        expect(!vm.inventoryInfos.isEmpty, "restarting must retain product presentation while refreshing")
        expect(!vm.hasCompletedRequest, "retained result is not a fresh scan")
        await eventually("presentation restart") { client.calls.count == 2 }
        vm.stopTracking()
        client.complete(1, .success(batch(["A"])))
        pass("restart retains product presentation without treating cached stock as fresh")
    }

    @MainActor
    private static func cachedResultsPersistence() {
        let suite = "InventoryCacheTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = TaskStore(preferences: preferences)
        let task = ScanTask(product: "A", appNotification: false, barkNotification: false)
        store.save(task, start: false)
        let date = Date(timeIntervalSince1970: 123456)
        store.runner(for: task.id).onResult?(CachedScanResult(inventories: batch(["A"]).inventories,
            location: store.defaults.region.location, updatedAt: date))
        let reopened = TaskStore(preferences: preferences)
        let runner = reopened.runner(for: task.id)
        expect(runner.inventoryInfos.first?.id == "A" && runner.lastSuccessAt == date, "relaunch restores product data and original timestamp")
        expect(!runner.isTracking && !runner.hasCompletedRequest, "restored results never look like a fresh scan")
        var changed = task
        changed.product = "B"
        reopened.save(changed, start: false)
        expect(reopened.runner(for: task.id).inventoryInfos.isEmpty, "editing SKU invalidates previous product")
        expect(TaskStore(preferences: preferences).runner(for: task.id).inventoryInfos.isEmpty, "invalidated product is not restored on relaunch")
        pass("cached results survive relaunch, remain stale and invalidate on SKU changes")
    }

    private static func cachedImageRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        // On-disk fixture from a prior launch; no metadata or image network request is needed.
        try png.write(to: directory.appendingPathComponent("41.image"))
        let first = ProductImageLoader(imageDirectory: directory)
        let restored = await first.imageData(for: "A")
        let relaunched = ProductImageLoader(imageDirectory: directory)
        let again = await relaunched.imageData(for: " a ")
        expect(restored == png && again == png, "image bytes survive loader recreation and normalize SKU")
        pass("disk image cache restores actual image bytes without network access")
    }

    @MainActor
    private static func desktopPersistence() {
        let suite = "InventoryDesktopTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(" a, B，a ", forKey: "partNumber")
        preferences.set(90, forKey: "countdown")
        let store = TaskStore(preferences: preferences)
        expect(store.tasks.map(\.product) == ["A", "B"], "legacy products migrate individually and deduplicate")
        expect(store.defaults.interval == 90 && store.runningCount == 0, "migration preserves interval without auto starting")
        var task = store.tasks[0]
        task.interval = 25
        task.appNotification = false
        store.save(task, start: false)
        var defaults = store.defaults
        defaults.interval = 120
        store.saveDefaults(defaults)
        let restored = TaskStore(preferences: preferences)
        expect(restored.tasks[0].resolved(using: restored.defaults).interval == 25, "custom interval survives default updates and relaunch")
        expect(restored.tasks[1].resolved(using: restored.defaults).interval == 120, "inherited interval follows defaults")
        expect(restored.validationError(for: ScanTask(product: "A")) != nil, "duplicate product and region rejected")
        var otherRegion = ScanTask(product: "A")
        otherRegion.region = ScanRegion(province: "上海", city: "上海", district: "浦东新区")
        expect(restored.validationError(for: otherRegion) == nil, "same product in different region accepted")
        restored.delete(restored.tasks[0])
        expect(TaskStore(preferences: preferences).tasks.count == 1, "deletion persists without repeating migration")
        pass("desktop migration, persistence, overrides and duplicate validation")
    }

    @MainActor
    private static func independentDesktopTasks() async {
        let clientA = ControlledClient(), clientB = ControlledClient()
        let clockA = ManualClock(), clockB = ManualClock()
        let a = ContentViewModel(client: clientA, notifier: RecordingNotifier(), clock: clockA)
        let b = ContentViewModel(client: clientB, notifier: RecordingNotifier(), clock: clockB)
        var defaults = ScanDefaults()
        defaults.appNotification = false
        a.configurationProvider = { defaults }
        a.startTracking(for: "A", location: "old", countdown: 60, pushNotificationSettings: settings)
        b.startTracking(for: "B", location: "B region", countdown: 90, pushNotificationSettings: settings)
        await eventually("independent starts") { clientA.calls.count == 1 && clientB.calls.count == 1 }
        clientA.complete(0, .success(batch(["A"])))
        clientB.complete(0, .success(batch(["B"])))
        await eventually("independent waits") { clockA.waiting == 1 && clockB.waiting == 1 }
        defaults.region = ScanRegion(province: "上海", city: "上海", district: "浦东新区")
        defaults.interval = 10
        b.stopTracking(preservingResults: true)
        expect(!b.inventoryInfos.isEmpty && b.lastSuccessAt != nil && a.isTracking, "stop retains last result and does not stop another task")
        clockA.advance(15)
        await eventually("changed defaults next round") { clientA.calls.count == 2 }
        expect(clientA.locations[1] == defaults.region.location, "next round resolves new region")
        clientA.complete(1, .success(batch(["A"])))
        await eventually("new interval") { clockA.waiting == 1 && a.countdownRemaining == 10 }
        a.stopTracking()
        pass("independent tasks, retained results and next-round default changes")
    }

    @MainActor
    private static func scheduledRequests() async {
        let underlying = ControlledClient()
        let scheduler = ScheduledInventoryClient(client: underlying, limit: 1)
        let first = Task { try await scheduler.fetchPickupInventory(for: ["A"], location: "A") }
        await eventually("scheduler active") { underlying.calls.count == 1 }
        let cancelled = Task { try await scheduler.fetchPickupInventory(for: ["B"], location: "B") }
        for _ in 0..<10 { await Task.yield() }
        cancelled.cancel()
        let third = Task { try await scheduler.fetchPickupInventory(for: ["C"], location: "C") }
        for _ in 0..<10 { await Task.yield() }
        expect(underlying.calls.count == 1, "request budget holds queued requests")
        underlying.complete(0, .success(batch(["A"])))
        _ = try? await first.value
        _ = try? await cancelled.value
        await eventually("scheduler skips cancellation") { underlying.calls.count == 2 }
        expect(underlying.calls[1] == ["C"] && underlying.maxActive == 1, "cancelled queued request never reaches network")
        underlying.complete(1, .success(batch(["C"])))
        _ = try? await third.value
        pass("shared request budget and queued cancellation")
    }

    @MainActor
    private static func powerLifecycle() async {
        let client = ControlledClient(), clock = ManualClock(), activity = RecordingActivity()
        let vm = ContentViewModel(client: client, notifier: RecordingNotifier(), clock: clock, activity: activity)
        vm.startTracking(for: "", location: "上海", countdown: 300, pushNotificationSettings: settings)
        expect(activity.starts == 0, "invalid input must not prevent sleep")
        vm.startTracking(for: "A", location: "上海", countdown: 300, pushNotificationSettings: settings)
        vm.startTracking(for: "A", location: "上海", countdown: 300, pushNotificationSettings: settings)
        await eventually("power first") { client.calls.count == 1 }
        expect(activity.starts == 1, "only one activity per monitoring run")
        client.complete(0, .success(batch(["A"])))
        await eventually("power waiting") { clock.waiting == 1 }
        clock.advance(3600)
        await eventually("wake overdue query") { client.calls.count == 2 }
        for _ in 0..<20 { await Task.yield() }
        expect(client.maxActive == 1 && client.calls.count == 2, "wake does not replay missed queries")
        client.complete(1, .failure(InventoryError.httpStatus(429, retryAfter: 600)))
        await eventually("power cooldown") { clock.waiting == 1 && vm.lastError != nil }
        clock.advance(300)
        await eventually("wake during cooldown") { clock.waiting == 1 && vm.countdownRemaining == 300 }
        expect(client.calls.count == 2, "wake preserves unexpired server cooldown")
        vm.stopTracking()
        expect(activity.ends == 1, "stop releases sleep prevention")
        vm.startTracking(for: "A", location: "上海", countdown: 300, pushNotificationSettings: settings)
        await eventually("power restart") { client.calls.count == 3 }
        expect(activity.starts == 2, "restart reacquires activity")
        vm.stopTracking()
        client.complete(2, .success(batch(["A"])))
        await eventually("power cleanup") { client.active == 0 }
        expect(activity.ends == 2 && !vm.isTracking, "stop during request releases activity")
        pass("monitoring activity lifecycle and wake deadline/cooldown handling")
    }

    private static func pollingPolicies() {
        var policy = InventoryPollingPolicy()
        policy.update(hasStock: false, succeeded: true, now: 0)
        expect(policy.interval(base: 300) == 300, "empty stock keeps normal frequency")
        policy.update(hasStock: true, succeeded: true, now: 10)
        expect(policy.phase == .accelerated && policy.interval(base: 300) == 15, "stock starts acceleration")
        expect(policy.interval(base: 2) == 2, "never slow a faster user interval")
        policy.update(hasStock: false, succeeded: true, now: 25)
        policy.update(hasStock: false, succeeded: false, now: 40)
        policy.update(hasStock: false, succeeded: true, now: 55)
        policy.update(hasStock: false, succeeded: true, now: 70)
        expect(policy.phase == .accelerated, "failed rounds break consecutive empty count")
        policy.update(hasStock: false, succeeded: true, now: 85)
        expect(policy.phase == .observing && policy.interval(base: 300) == 30, "three empty rounds start observation")
        policy.update(hasStock: true, succeeded: true, now: 100)
        expect(policy.phase == .accelerated, "returning stock accelerates again")
        policy.update(hasStock: true, succeeded: true, now: 700)
        expect(policy.phase == .observing, "continuous availability cannot renew ten minute budget")
        policy.update(hasStock: true, succeeded: true, now: 1000)
        expect(policy.phase == .regular, "continuous stock eventually returns to normal")
        policy.update(hasStock: false, succeeded: true, now: 1300)
        policy.update(hasStock: true, succeeded: false, now: 1600)
        expect(policy.phase == .regular, "partial or failed response cannot trigger acceleration")
        policy.update(hasStock: true, succeeded: true, now: 1900)
        expect(policy.phase == .accelerated, "new release can start another activity window")
        pass("adaptive polling transitions, time caps, failed rounds and faster user intervals")

        var notifications = InventoryNotificationPolicy()
        let available = ProductInventory(id: "A", stores: stock("A"))
        let empty = ProductInventory(id: "A", stores: stock("A", available: false))
        expect(notifications.shouldNotify(available, now: 0), "notify first stock immediately")
        expect(!notifications.shouldNotify(available, now: 15), "suppress repeated accelerated alerts")
        expect(notifications.shouldNotify(available, now: 60), "repeat reminder at sixty seconds")
        let expanded = ProductInventory(id: "A", stores: stock("A") + [StoreInventoryInfo(storeName: "新门店", storeImageUrl: "", productName: "A", isProductAvailable: true, productId: "A", storeNumber: "R002")])
        expect(notifications.shouldNotify(expanded, now: 61), "new store bypasses notification cooldown")
        expect(!notifications.shouldNotify(empty, now: 62), "empty stock resets notifications without alert")
        expect(notifications.shouldNotify(available, now: 63), "restock alerts immediately")
        pass("availability notification cooldown and new-store alerts")
    }

    @MainActor
    private static func adaptiveSchedule() async {
        let client = ControlledClient(), clock = ManualClock()
        let vm = ContentViewModel(client: client, notifier: RecordingNotifier(), clock: clock)
        vm.startTracking(for: "A,B", location: "上海", countdown: 300, pushNotificationSettings: settings)
        await eventually("adaptive first") { client.calls.count == 1 }
        client.complete(0, .success(batch(["A", "B"])))
        await eventually("adaptive waiting") { clock.waiting == 1 }
        expect(vm.countdownRemaining == 15 && vm.countdownLabel.contains("加速查询中"), "UI displays accelerated countdown")
        clock.advance(15)
        await eventually("adaptive batch") { client.calls.count == 2 }
        expect(client.calls[1] == ["A", "B"] && client.maxActive == 1, "acceleration preserves single batch")
        client.complete(1, .failure(InventoryError.httpStatus(429, retryAfter: 600)))
        await eventually("adaptive cooldown") { vm.lastError != nil && clock.waiting == 1 }
        expect(vm.countdownRemaining == 600 && vm.countdownLabel.contains("重试"), "server cooldown overrides acceleration and UI")
        vm.stopTracking()
        expect(vm.pollingPhase == .regular && !vm.hasCompletedRequest, "stop clears adaptive state")
        pass("accelerated batch countdown and rate-limit UI priority")
    }

    @MainActor
    private static func slowNotifications() async {
        let client = ControlledClient(), clock = ManualClock(), notifier = SlowNotifier()
        let vm = ContentViewModel(client: client, notifier: notifier, clock: clock)
        vm.startTracking(for: "A", location: "上海", countdown: 300, pushNotificationSettings: settings)
        await eventually("slow push first batch") { client.calls.count == 1 }
        client.complete(0, .success(batch(["A"])))
        await eventually("slow push waiting") { notifier.calls == 1 && clock.waiting == 1 }
        clock.advance(15)
        await eventually("poll despite pending push") { client.calls.count == 2 }
        client.complete(1, .success(batch(["A"])))
        await eventually("no push backlog") { vm.trackingCount == 2 && clock.waiting == 1 }
        expect(notifier.calls == 1, "slow push cannot accumulate overlapping tasks")
        vm.stopTracking()
        expect(!vm.isTracking, "stop cancels pending push")
        pass("slow notifications never block polling or accumulate tasks")
    }

    @MainActor
    private static func lifecycle() async {
        let client = ControlledClient(), notifier = RecordingNotifier(), clock = ManualClock()
        let vm = ContentViewModel(client: client, notifier: notifier, clock: clock)
        vm.startTracking(for: "OLD", location: "上海", countdown: 2, pushNotificationSettings: settings)
        await eventually("old request") { client.calls.count == 1 }
        vm.stopTracking()
        client.complete(0, .success(batch(["OLD"])))
        await eventually("late response") { client.active == 0 }
        expect(vm.inventoryInfos.isEmpty && vm.trackingCount == 0 && notifier.rounds.isEmpty, "stop rejects late results and notifications")
        pass("stop rejects late batch response and notification")

        vm.startTracking(for: "OLD", location: "上海", countdown: 2, pushNotificationSettings: settings)
        await eventually("old second") { client.calls.count == 2 }
        vm.stopTracking()
        vm.startTracking(for: "NEW", location: "北京", countdown: 2, pushNotificationSettings: settings)
        await eventually("new request") { client.calls.count == 3 }
        client.complete(2, .success(batch(["NEW"])))
        await eventually("new result") { vm.trackingCount == 1 }
        client.complete(1, .success(batch(["OLD"])))
        await eventually("late old result") { client.active == 0 }
        expect(vm.inventoryInfos.map(\.id) == ["NEW"] && notifier.rounds.count == 1, "restart isolates old generation")
        vm.stopTracking()
        pass("restart isolates old generation")
    }

    @MainActor
    private static func schedule() async {
        let client = ControlledClient(), notifier = RecordingNotifier(), clock = ManualClock()
        let vm = ContentViewModel(client: client, notifier: notifier, clock: clock)
        for interval in [0, -1, Int.max] {
            vm.startTracking(for: "ABC", location: "上海", countdown: interval, pushNotificationSettings: settings)
            expect(!vm.isTracking && vm.lastError != nil, "invalid interval")
        }
        vm.startTracking(for: " ,， ", location: "上海", countdown: 2, pushNotificationSettings: settings)
        expect(!vm.isTracking, "empty products")
        vm.startTracking(for: "ABC", location: "  ", countdown: 2, pushNotificationSettings: settings)
        expect(!vm.isTracking && client.calls.isEmpty, "invalid input must not request")
        pass("invalid inputs make no requests")
        vm.startTracking(for: " a , A， b,b ", location: " 上海 ", countdown: 2, pushNotificationSettings: settings)
        await eventually("batch") { client.calls.count == 1 }
        expect(client.calls == [["A", "B"]] && client.locations == ["上海"], "deduplicated products in one batch")
        clock.advance(10)
        for _ in 0..<20 { await Task.yield() }
        expect(client.calls.count == 1 && client.maxActive == 1, "slow batch cannot overlap")
        client.complete(0, .success(batch(["A", "B"])))
        await eventually("overdue next round") { client.calls.count == 2 }
        expect(client.maxActive == 1, "serial rounds")
        vm.stopTracking()
        client.complete(1, .success(batch(["A", "B"])))
        await eventually("cleanup") { client.active == 0 }
        pass("deduplicated products share one request; slow rounds never overlap")

        let timedClient = ControlledClient(), timedClock = ManualClock()
        let timed = ContentViewModel(client: timedClient, notifier: RecordingNotifier(), clock: timedClock)
        timed.startTracking(for: "A,B", location: "上海", countdown: 2, pushNotificationSettings: settings)
        await eventually("timed first") { timedClient.calls.count == 1 }
        expect(!timed.hasCompletedRequest, "first request keeps the header hidden")
        timedClient.complete(0, .success(batch(["A", "B"])))
        await eventually("sleep") { timedClock.waiting == 1 }
        expect(timed.hasCompletedRequest, "first completed request reveals the header")
        timedClock.advance(1)
        await eventually("one second") { timed.countdownRemaining == 1 && timedClock.waiting == 1 }
        expect(timedClient.calls.count == 1, "no early request")
        timedClock.advance(1)
        await eventually("exact boundary") { timedClient.calls.count == 2 }
        expect(timed.hasCompletedRequest, "subsequent requests preserve the countdown header")
        timed.stopTracking()
        expect(!timed.hasCompletedRequest, "stop resets first-load state")
        timedClient.complete(1, .success(batch(["A", "B"])))
        await eventually("cleanup") { timedClient.active == 0 }
        pass("interval is N seconds, not N+1")

        let minuteClient = ControlledClient(), minuteClock = ManualClock()
        let minuteTimer = ContentViewModel(client: minuteClient, notifier: RecordingNotifier(), clock: minuteClock)
        minuteTimer.startTracking(for: "A", location: "上海", countdown: 125, pushNotificationSettings: settings)
        await eventually("minute timer request") { minuteClient.calls.count == 1 }
        minuteClient.complete(0, .success(InventoryBatchResult(inventories: [ProductInventory(id: "A", stores: stock("A", available: false))], failures: [:])))
        await eventually("minute timer waiting") { minuteClock.waiting == 1 }
        expect(minuteTimer.countdownText == "02:05", "125 remaining seconds must display 02:05, not elapsed seconds")
        minuteClock.advance(65)
        await eventually("minute boundary") { minuteTimer.countdownRemaining == 60 && minuteClock.waiting == 1 }
        expect(minuteTimer.countdownText == "01:00", "60 remaining seconds must display 01:00")
        minuteClock.advance(1)
        await eventually("below minute") { minuteTimer.countdownRemaining == 59 && minuteClock.waiting == 1 }
        expect(minuteTimer.countdownText == "00:59", "minute rollover must display 00:59")
        minuteTimer.stopTracking()
        expect(minuteTimer.countdownText == "00:00", "stopping clears countdown text")
        pass("countdown label uses remaining minutes and seconds across minute boundaries")

    }

    @MainActor
    private static func failureRecovery() async {
        let client = ControlledClient(), notifier = RecordingNotifier(), clock = ManualClock()
        let vm = ContentViewModel(client: client, notifier: notifier, clock: clock)
        vm.startTracking(for: "A,B", location: "上海", countdown: 2, pushNotificationSettings: settings)
        await eventually("initial") { client.calls.count == 1 }
        client.complete(0, .success(batch(["A", "B"])))
        await eventually("initial done") { clock.waiting == 1 }
        clock.advance(2)
        await eventually("partial") { client.calls.count == 2 }
        client.complete(1, .success(InventoryBatchResult(inventories: [ProductInventory(id: "B", stores: stock("B", available: false))], failures: ["A": .invalidInventory])))
        await eventually("partial done") { notifier.rounds.count == 2 && clock.waiting == 1 }
        expect(vm.inventoryInfos.count == 2 && vm.inventoryInfos.first { $0.id == "A" }!.stores[0].isProductAvailable, "preserve failed product")
        expect(vm.trackingCount == 1 && vm.lastError != nil && notifier.rounds[1].map(\.id) == ["B"], "partial error cannot notify stale A or count success")
        expect(vm.countdown == 5, "error backoff")
        pass("partial batch failure preserves previous results and excludes stale notifications")
        clock.advance(5)
        await eventually("blocked") { client.calls.count == 3 }
        client.complete(2, .failure(InventoryError.httpStatus(541, retryAfter: 60)))
        await eventually("blocked done") { clock.waiting == 1 && notifier.rounds.count == 3 }
        expect(vm.countdown == 60 && vm.trackingCount == 1 && notifier.rounds[2].isEmpty && vm.inventoryInfos.count == 2, "blocked is not empty inventory")
        pass("HTTP failure preserves results and honors cooldown")
        clock.advance(60)
        await eventually("recovery") { client.calls.count == 4 }
        let recovered = InventoryBatchResult(inventories: [ProductInventory(id: "A", stores: []), ProductInventory(id: "B", stores: stock("B"))], failures: [:])
        client.complete(3, .success(recovered))
        await eventually("recovered") { vm.trackingCount == 2 && clock.waiting == 1 }
        expect(vm.inventoryInfos.map(\.id) == ["B"] && vm.lastError == nil && vm.countdown == 2, "empty success clears old product and resets backoff")
        clock.advance(2)
        await eventually("repeat") { client.calls.count == 5 }
        client.complete(4, .success(recovered))
        await eventually("repeat done") { vm.trackingCount == 3 && notifier.rounds.count == 5 }
        expect(notifier.rounds[3].last?.id == "B" && notifier.rounds[4].last?.id == "B", "preserve repeated availability notifications")
        vm.stopTracking()
        pass("empty success clears old data; recovery retains repeated notifications")
    }

    @MainActor
    private static func urls() throws {
        let location = "上海 长宁区&pl=false?# +"
        let url = try InventoryClient.requestURL(productIds: [" abc/a ", "ABC/A", "DEF/A&x=1"], location: location)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        expect(url.path == "/shop/retail/pickup-message" && items.count == 5, "pickup endpoint and merged deduplicated query")
        expect(items.first { $0.name == "parts.0" }?.value == "ABC/A" && items.first { $0.name == "parts.1" }?.value == "DEF/A&X=1", "sequential product indices")
        expect(items.first { $0.name == "location" }?.value == location && url.absoluteString.contains("%2B"), "query values preserved without injection")
        pass("pickup URL merges products and encodes individual query values")
        let title = "iPhone / Pro?#中文", body = "店 / A?x=1#,+"
        let bark = InventoryNotifier.barkURL(base: "https://api.day.app/test-key/?sound=bell", title: title, body: body)!
        let components = URLComponents(url: bark, resolvingAgainstBaseURL: false)!
        let segments = components.percentEncodedPath.split(separator: "/").map { String($0).removingPercentEncoding! }
        expect(segments == ["test-key", title, body] && components.query == "sound=bell", "Bark segments and options")
        expect(stock("A")[0].id == stock("A", available: false)[0].id && stock("A")[0].id != stock("B")[0].id, "stable per-product store identity")
        pass("Bark encoding and stable list identity")
    }

    @MainActor
    private static func presentation() async {
        let inventory = ProductInventory(id: "MJTD4CH/A", stores: stock("MJTD4CH/A") + stock("MJTD4CH/A", available: false))
        expect(inventory.availableStores.count == 1 && inventory.availabilitySummary == "上海 / 店?#", "summary includes only available stores")
        expect(ProductInventory(id: "A", stores: []).availabilitySummary == "当前无门店可供取货", "zero availability text")
        expect(inventory.purchaseURL?.absoluteString == "https://www.apple.com.cn/shop/product/mjtd4ch/a", "SKU purchase link")
        expect(AppleProductPage.purchaseURL(for: "MJTD4CH/A?x=1") == nil, "invalid SKU cannot inject link parameters")
        let html = #"<meta content='https://store.storeimages.cdn-apple.com/product.jpg?wid=1200&amp;hei=630' property='og:image'>"#
        expect(AppleProductPage.imageURL(in: html)?.query == "wid=1200&hei=630", "attribute order and HTML entity decoding")
        expect(AppleProductPage.imageURL(in: #"<meta property="og:image" content="https://example.com/not-apple.jpg">"#) == nil, "only Apple product images")
        pass("product header summary, SKU purchase URL and image metadata parsing")
        let selectionHTML = #"window.PRODUCT_SELECTION_BOOTSTRAP = { productSelectionData: {"products":[{"partNumber":"OTHER/A","imageKey":"wrong"},{"partNumber":"MJTD4CH/A","imageKey":"right"}],"imageDictionary":{"right":{"sources":[{"srcSet":"https://store.storeimages.cdn-apple.com/1/as-images.apple.com/is/silver?wid=940&hei=1112&fmt=png-alpha&.v=old"}]}},"label":"brace } inside string"} };"#
        let source = AppleProductPage.productImageURL(in: selectionHTML, product: " mjtd4ch/a ")!
        expect(source.path.hasSuffix("/silver"), "exact SKU selects its image; braces in JSON strings do not truncate data")
        expect(AppleProductPage.productImageURL(in: selectionHTML, product: "MISSING/A") == nil, "missing SKU cannot use another variant")
        expect(AppleProductPage.productImageURL(in: selectionHTML.replacingOccurrences(of: "store.storeimages.cdn-apple.com", with: "example.com"), product: "MJTD4CH/A") == nil, "untrusted product image rejected")
        let thumbnail = AppleProductPage.thumbnailURL(for: source)!
        expect(thumbnail.query == "wid=192&hei=192&fmt=png-alpha", "square 3x PNG drops old rendition token")
        pass("exact SKU thumbnail mapping and resolution")


        let queue = StubQueue([.init(type: "text/html", body: html), .init(status: 404, type: "text/html")])
        StubURLProtocol.queue = queue
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let loader = ProductImageLoader(configuration: config)
        async let first = loader.imageURL(for: "MJTD4CH/A")
        async let second = loader.imageURL(for: " mjtd4ch/a ")
        let images = await (first, second)
        expect(images.0 != nil && images.0 == images.1 && queue.requests.count == 1, "concurrent image metadata calls share one request")
        let cached = await loader.imageURL(for: "MJTD4CH/A")
        expect(cached == images.0 && queue.requests.count == 1, "stock refresh reuses metadata")
        let missing = await loader.imageURL(for: "MJYC4CH/A")
        let missingAgain = await loader.imageURL(for: "MJYC4CH/A")
        expect(missing == nil && missingAgain == nil && queue.requests.count == 2, "failed images are cached briefly without repeated requests")
        pass("product image metadata deduplicates, caches success and backs off on failure")
        for status in [200, 404] {
            let imageQueue = StubQueue([.init(type: "text/html", body: selectionHTML), .init(status: status, type: "image/png")])
            StubURLProtocol.queue = imageQueue
            let imageLoader = ProductImageLoader(configuration: config)
            let selected = await imageLoader.imageURL(for: "MJTD4CH/A")
            expect(selected == (status == 200 ? thumbnail : source), "thumbnail failure falls back to exact source")
            expect(imageQueue.requests.count == 2 && imageQueue.requests.last?.httpMethod == "HEAD", "validate rendition without downloading full image")
        }
        pass("thumbnail validation and original-image fallback")

    }

    @MainActor
    private static func makeClient(_ responses: [StubResponse], now: @escaping () -> Date = Date.init) -> (InventoryClient, StubQueue) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let queue = StubQueue(responses)
        StubURLProtocol.queue = queue
        return (InventoryClient(configuration: config, now: now), queue)
    }

    @MainActor
    private static func client() async throws {
        let (normal, queue) = makeClient([.init(body: fixture(["A": part("available"), "B": part("unavailable"), "C": part("ineligible"), "D": part("available", eligible: false)]))])
        let result = try await normal.fetchPickupInventory(for: [" a ", "A", "B", "C", "D"], location: "上海")
        expect(queue.requests.count == 1 && result.inventories.count == 4 && result.failures.isEmpty, "one HTTP request for all products")
        expect(result.inventories.map { $0.stores[0].isProductAvailable } == [true, false, false, false], "only eligible available pickup triggers stock")
        expect(result.inventories[0].stores[0].productName == "测试产品" && result.inventories[0].stores[0].storeImageUrl.isEmpty, "regular title and optional image")
        expect(queue.requests[0].value(forHTTPHeaderField: "Cookie") == nil && queue.requests[0].value(forHTTPHeaderField: "Referer") == nil, "no session headers")
        pass("native batch pickup parsing; selection flag never overrides unavailable/ineligible")

        var normalized = part("available")
        normalized["partNumber"] = "a"
        normalized.removeValue(forKey: "messageTypes")
        let (partial, _) = makeClient([.init(body: fixture(["normalized-key": normalized, "B": part("new-unknown-state")]))])
        let mixed = try await partial.fetchPickupInventory(for: ["A", "B", "C"], location: "上海")
        expect(mixed.inventories.map(\.id) == ["A"] && mixed.inventories[0].stores[0].productName == "A", "partNumber fallback and missing title fallback")
        expect(Set(mixed.failures.keys) == Set(["B", "C"]), "unknown and missing product must remain failures")
        pass("normalized SKU lookup, optional title, and per-product unknown/missing errors")

        for body in ["{}", "{\"body\":{}}", "{\"body\":{\"stores\":null}}", "{\"head\":{\"status\":\"unknown\"},\"body\":{\"stores\":[]}}", fixture(["A": part("available")], headStatus: 400)] {
            let (bad, _) = makeClient([.init(body: body)])
            do { _ = try await bad.fetchPickupInventory(for: ["A"], location: "上海"); fatalError("expected invalid schema") }
            catch InventoryError.invalidInventory {}
        }
        let (empty, _) = makeClient([.init(body: "{\"body\":{\"stores\":[]}}")])
        let noStores = try await empty.fetchPickupInventory(for: ["A", "B"], location: "上海")
        expect(noStores.inventories.count == 2 && noStores.inventories.allSatisfy { $0.stores.isEmpty } && noStores.failures.isEmpty, "explicit empty stores is a successful response")
        pass("missing/schema-error responses fail; explicit empty stores succeeds")

        let (numericHead, _) = makeClient([.init(body: "{\"head\":{\"status\":200},\"body\":{\"stores\":[]}}")])
        _ = try await numericHead.fetchPickupInventory(for: ["A"], location: "上海")
        pass("Apple string status and numeric status both decode; malformed status fails")

        var date = Date(timeIntervalSince1970: 1_700_000_000)
        let (blocked, blockedQueue) = makeClient([.init(status: 541, type: "text/html"), .init(body: fixture(["A": part("available")]))], now: { date })
        for _ in 0..<2 {
            do { _ = try await blocked.fetchPickupInventory(for: ["A"], location: "上海"); fatalError("expected blocked") }
            catch InventoryError.httpStatus(let status, let wait) { expect(status == 541 && wait == 60, "blocked cooldown") }
        }
        expect(blockedQueue.requests.count == 1, "no immediate retries or cooldown requests")
        date.addTimeInterval(60)
        _ = try await blocked.fetchPickupInventory(for: ["A"], location: "上海")
        expect(blockedQueue.requests.count == 2, "one recovery request after cooldown")
        pass("541 waits before recovery without browser/session or immediate retry")

        let (limited, limitedQueue) = makeClient([.init(status: 429, headers: ["Retry-After": "120"])], now: { date })
        for _ in 0..<2 {
            do { _ = try await limited.fetchPickupInventory(for: ["A"], location: "上海"); fatalError("expected rate limit") }
            catch InventoryError.httpStatus(let status, let wait) { expect(status == 429 && wait == 120, "Retry-After") }
        }
        expect(limitedQueue.requests.count == 1, "rate limit uses shared cooldown")
        expect(InventoryRetryPolicy.retryAfter("Tue, 14 Nov 2023 22:15:20 GMT", now: Date(timeIntervalSince1970: 1_700_000_000)) == 120, "HTTP-date Retry-After")
        expect(InventoryRetryPolicy.delay(interval: 2, failures: 2) == 10 && InventoryRetryPolicy.delay(interval: 2, failures: 9) == 900, "bounded backoff")
        pass("429 cooldown, HTTP-date Retry-After, and bounded exponential backoff")

        let (html, _) = makeClient([.init(type: "text/html", body: "<html>blocked</html>")])
        do { _ = try await html.fetchPickupInventory(for: ["A"], location: "上海"); fatalError("HTML is not inventory") }
        catch InventoryError.invalidResponse {}
        pass("HTTP 200 HTML is an error, never empty stock")

        let (cancelled, cancelQueue) = makeClient([])
        let task = Task { try await cancelled.fetchPickupInventory(for: ["A"], location: "上海") }
        task.cancel()
        do { _ = try await task.value; fatalError("expected cancellation") } catch is CancellationError {}
        expect(cancelQueue.requests.isEmpty, "cancelled task sends no HTTP")
        pass("cancelled client sends no HTTP request")
    }
}
