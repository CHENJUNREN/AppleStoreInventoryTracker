import Foundation

@MainActor
protocol InventoryFetching {
    func fetchPickupInventory(for productIds: [String], location: String) async throws -> InventoryBatchResult
}

struct InventoryBatchResult {
    let inventories: [ProductInventory]
    let failures: [String: InventoryError]
}

enum InventoryError: LocalizedError {
    case invalidInput
    case httpStatus(Int, retryAfter: Int?)
    case invalidResponse
    case invalidInventory
    case network(Int)

    var errorDescription: String? {
        switch self {
        case .invalidInput: return "型号、地区或查询间隔无效"
        case .httpStatus(let status, _): return "Apple 到店取货查询失败（HTTP \(status)）"
        case .invalidResponse: return "Apple 返回了非预期响应"
        case .invalidInventory: return "到店取货数据缺失或格式不符合预期"
        case .network(let code): return "库存请求网络错误（\(code)）"
        }
    }

    var retryAfter: Int? {
        if case .httpStatus(_, let delay) = self { return delay }
        return nil
    }
}

enum InventoryRetryPolicy {
    static func delay(interval: Int, failures: Int, retryAfter: Int? = nil) -> Int {
        let base = max(5, min(interval, 900))
        let backoff = min(900, base * (1 << min(max(0, failures - 1), 8)))
        return max(interval, backoff, retryAfter ?? 0)
    }

    static func retryAfter(_ value: String?, now: Date = Date()) -> Int? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
            return Int(min(seconds.rounded(.up), Double(Int.max / 2)))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, Int(date.timeIntervalSince(now).rounded(.up)))
    }
}

private final class NoInventoryRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // A redirect is not a successful pickup response.
        completionHandler(nil)
    }
}

@MainActor
final class InventoryClient: InventoryFetching {
    private let session: URLSession
    private let now: () -> Date
    private var blockedUntil: Date?
    private var blockedStatus: Int?

    init(configuration: URLSessionConfiguration = .ephemeral, now: @escaping () -> Date = Date.init) {
        self.now = now
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: NoInventoryRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    static func normalizedProducts(_ products: [String]) -> [String] {
        var seen = Set<String>()
        return products.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func requestURL(productIds: [String], location: String) throws -> URL {
        let products = normalizedProducts(productIds)
        let location = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !products.isEmpty, !location.isEmpty else { throw InventoryError.invalidInput }
        var components = URLComponents(string: "https://www.apple.com.cn/shop/retail/pickup-message")!
        components.queryItems = [
            .init(name: "pl", value: "true"), .init(name: "mts.0", value: "regular"),
            .init(name: "location", value: location)
        ] + products.enumerated().map { .init(name: "parts.\($0.offset)", value: $0.element) }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw InventoryError.invalidInput }
        return url
    }

    func fetchPickupInventory(for productIds: [String], location: String) async throws -> InventoryBatchResult {
        try Task.checkCancellation()
        let products = Self.normalizedProducts(productIds)
        let url = try Self.requestURL(productIds: products, location: location)
        if let blockedUntil, let blockedStatus, blockedUntil > now() {
            throw InventoryError.httpStatus(blockedStatus, retryAfter: Int(ceil(blockedUntil.timeIntervalSince(now()))))
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        let data: Data
        let rawResponse: URLResponse
        do { (data, rawResponse) = try await session.data(for: request) }
        catch {
            try Task.checkCancellation()
            throw InventoryError.network((error as NSError).code)
        }
        try Task.checkCancellation()
        guard let response = rawResponse as? HTTPURLResponse else { throw InventoryError.invalidResponse }
        guard (200...299).contains(response.statusCode) else {
            var wait = InventoryRetryPolicy.retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now())
            if [401, 403, 429, 503, 541].contains(response.statusCode) { wait = max(60, wait ?? 0) }
            if let wait, wait > 0 {
                blockedUntil = now().addingTimeInterval(TimeInterval(wait))
                blockedStatus = response.statusCode
            }
            // No immediate retries: the scanner owns backoff, including for blocked requests.
            throw InventoryError.httpStatus(response.statusCode, retryAfter: wait)
        }
        guard response.mimeType?.lowercased() == "application/json" else { throw InventoryError.invalidResponse }
        let model: PickupAPIModel
        do { model = try JSONDecoder().decode(PickupAPIModel.self, from: data) }
        catch { throw InventoryError.invalidInventory }
        guard model.head?.status == nil || model.head?.status == 200 else { throw InventoryError.invalidInventory }
        var inventories: [ProductInventory] = []
        var failures: [String: InventoryError] = [:]
        for product in products {
            do {
                let stores = try model.body.stores.map { store -> StoreInventoryInfo in
                    // Some responses normalize the dictionary key but retain partNumber.
                    let item = store.partsAvailability[product] ?? store.partsAvailability.values.first {
                        $0.partNumber?.uppercased() == product
                    }
                    guard let item, let display = item.pickupDisplay?.lowercased(),
                          ["available", "unavailable", "ineligible"].contains(display) else {
                        throw InventoryError.invalidInventory
                    }
                    return StoreInventoryInfo(storeName: store.storeName, storeImageUrl: store.storeImageUrl ?? "",
                        productName: item.messageTypes?.regular?.storePickupProductTitle ?? product,
                        isProductAvailable: display == "available" && item.storePickEligible != false,
                        productId: product, storeNumber: store.storeNumber)
                }
                inventories.append(ProductInventory(id: product, stores: stores.sorted { $0.storeName > $1.storeName }))
            } catch { failures[product] = .invalidInventory }
        }
        blockedUntil = nil
        blockedStatus = nil
        return InventoryBatchResult(inventories: inventories, failures: failures)
    }
}
