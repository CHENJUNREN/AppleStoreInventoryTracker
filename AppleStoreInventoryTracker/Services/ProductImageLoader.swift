import Foundation

actor ProductImageLoader {
    static let shared = ProductImageLoader()
    private struct CachedImage {
        let url: URL?
        let expiry: Date
    }
    private let session: URLSession
    private var cache: [String: CachedImage] = [:]
    private var pending: [String: Task<URL?, Never>] = [:]

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    func imageURL(for product: String) async -> URL? {
        guard let pageURL = AppleProductPage.purchaseURL(for: product) else { return nil }
        let key = pageURL.absoluteString
        if let entry = cache[key], entry.expiry > Date() { return entry.url }
        if let task = pending[key] { return await task.value }
        let task = Task { [session] () -> URL? in
            do {
                let (data, response) = try await session.data(from: pageURL)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      response.mimeType == "text/html", let finalURL = response.url,
                      finalURL.host == "www.apple.com.cn",
                      Self.matchesProduct(finalURL, product: product),
                      let html = String(data: data, encoding: .utf8) else { return nil }
                guard let source = AppleProductPage.productImageURL(in: html, product: product) else {
                    return AppleProductPage.imageURL(in: html)
                }
                if let thumbnail = AppleProductPage.thumbnailURL(for: source) {
                    var request = URLRequest(url: thumbnail)
                    request.httpMethod = "HEAD"
                    if let (_, check) = try? await session.data(for: request),
                       let check = check as? HTTPURLResponse, check.statusCode == 200,
                       check.mimeType?.hasPrefix("image/") == true {
                        return thumbnail
                    }
                }
                // A failed thumbnail rendition still leaves the exact original product image.
                return source
            } catch { return nil }
        }
        pending[key] = task
        let url = await task.value
        cache[key] = CachedImage(url: url, expiry: Date().addingTimeInterval(url == nil ? 300 : 86400))
        pending[key] = nil
        return url
    }

    private static func matchesProduct(_ url: URL, product: String) -> Bool {
        let marker = "/" + product.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let path = url.path.lowercased()
        return path.hasSuffix(marker) || path.contains(marker + "/")
    }
}
