import Foundation

/// Catalog requests are separate from stock polling and share a daily disk cache.
actor IPhoneCatalogService {
    static let shared = IPhoneCatalogService()
    static let indexURL = URL(string: "https://www.apple.com.cn/shop/buy-iphone")!
    private let session: URLSession
    private let cacheURL: URL?
    private let now: () -> Date
    private var cached: IPhoneCatalog?
    private var pending: Task<IPhoneCatalog, Error>?
    private var retryAt: Date?

    init(configuration: URLSessionConfiguration = .ephemeral,
         cacheURL: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AppleStoreInventoryTracker/iPhoneCatalog-v1.json"),
         now: @escaping () -> Date = Date.init) {
        self.cacheURL = cacheURL
        self.now = now
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let value = try? JSONDecoder().decode(IPhoneCatalog.self, from: data),
           !value.models.isEmpty, value.models.allSatisfy({ !$0.variants.isEmpty }) {
            cached = value
        }
    }

    deinit { session.invalidateAndCancel() }

    func cachedCatalog() -> IPhoneCatalog? { cached }

    func load(forceRefresh: Bool = false) async throws -> IPhoneCatalog {
        if !forceRefresh, let cached, now().timeIntervalSince(cached.updatedAt) < 86400 { return cached }
        if let pending { return try await pending.value }
        if let retryAt, now() < retryAt { throw IPhoneCatalogError.coolingDown }
        let task = Task { try await self.fetchCatalog() }
        pending = task
        do {
            let result = try await task.value
            cached = result
            pending = nil
            retryAt = nil
            if let cacheURL, let data = try? JSONEncoder().encode(result) {
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
            }
            return result
        } catch {
            pending = nil
            // A refresh failure must not erase the last complete catalog or trigger a retry storm.
            retryAt = max(retryAt ?? now(), now().addingTimeInterval(60))
            throw error
        }
    }

    private func fetchCatalog() async throws -> IPhoneCatalog {
        let pages = try IPhoneCatalogParser.productPages(in: await fetchHTML(Self.indexURL))
        var models: [IPhoneModel] = []
        var seen = Set<String>()
        for page in pages {
            try Task.checkCancellation()
            for model in try IPhoneCatalogParser.models(in: await fetchHTML(page)) {
                guard seen.insert(model.id).inserted else { throw IPhoneCatalogError.invalidPage }
                models.append(model)
            }
        }
        guard !models.isEmpty else { throw IPhoneCatalogError.emptyCatalog }
        return IPhoneCatalog(updatedAt: now(), models: models)
    }

    private func fetchHTML(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, rawResponse) = try await session.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse else { throw IPhoneCatalogError.invalidPage }
        guard response.statusCode == 200 else {
            if let wait = InventoryRetryPolicy.retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now()) {
                retryAt = now().addingTimeInterval(TimeInterval(wait))
            }
            throw IPhoneCatalogError.httpStatus(response.statusCode)
        }
        guard response.url?.host == "www.apple.com.cn", response.url?.scheme == "https",
              response.url?.path == url.path, response.mimeType == "text/html",
              data.count <= 8 * 1024 * 1024, let html = String(data: data, encoding: .utf8) else {
            throw IPhoneCatalogError.invalidPage
        }
        return html
    }
}
