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
        await lifecycle()
        await schedule()
        await failureRecovery()
        try urls()
        await presentation()
        try await client()
        print("\(passed) regression scenarios passed; no external requests or notifications sent.")
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
        timedClient.complete(0, .success(batch(["A", "B"])))
        await eventually("sleep") { timedClock.waiting == 1 }
        timedClock.advance(1)
        await eventually("one second") { timed.countdownRemaining == 1 && timedClock.waiting == 1 }
        expect(timedClient.calls.count == 1, "no early request")
        timedClock.advance(1)
        await eventually("exact boundary") { timedClient.calls.count == 2 }
        timed.stopTracking()
        timedClient.complete(1, .success(batch(["A", "B"])))
        await eventually("cleanup") { timedClient.active == 0 }
        pass("interval is N seconds, not N+1")
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
        await eventually("repeat done") { vm.trackingCount == 3 }
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
