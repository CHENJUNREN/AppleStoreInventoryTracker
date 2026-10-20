import Foundation
import ImageIO

actor ProductImageLoader {
    static let shared = ProductImageLoader()
    private struct CachedImage {
        let url: URL?
        let expiry: Date
    }
    private let session: URLSession
    private let imageDirectory: URL?
    private var imageRequests: [String: Task<Data?, Never>] = [:]
    private var cache: [String: CachedImage] = [:]
    private var pending: [String: Task<URL?, Never>] = [:]

    init(configuration: URLSessionConfiguration = .ephemeral, imageDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("AppleStoreInventoryTracker/ProductImages", isDirectory: true)) {
        self.imageDirectory = imageDirectory
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

    /// Cache the actual image bytes so relaunching does not depend on the product page or network.
    func imageData(for product: String) async -> Data? {
        let key = product.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let file = imageDirectory?.appendingPathComponent(key.utf8.map { String(format: "%02x", $0) }.joined() + ".image")
        if let file, let data = try? Data(contentsOf: file), Self.isImage(data) { return data }
        if let pending = imageRequests[key] { return await pending.value }
        let request = Task { () -> Data? in
            guard let url = await self.imageURL(for: key) else { return nil }
            do {
                let (data, response) = try await self.session.data(from: url)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      Self.isImage(data) else { return nil }
                if let file {
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: file, options: .atomic)
                }
                return data
            } catch { return nil }
        }
        imageRequests[key] = request
        let data = await request.value
        imageRequests[key] = nil
        return data
    }

    private static func isImage(_ data: Data) -> Bool {
        guard data.count <= 10 * 1024 * 1024,
              let image = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(image) > 0
    }

    private static func matchesProduct(_ url: URL, product: String) -> Bool {
        let marker = "/" + product.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let path = url.path.lowercased()
        return path.hasSuffix(marker) || path.contains(marker + "/")
    }
}
