import Foundation

enum AppleProductPage {
    /// Apple redirects this SKU URL to the matching product configuration.
    static func purchaseURL(for product: String) -> URL? {
        let sku = product.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard sku.range(of: "^[a-z0-9]+/a$", options: .regularExpression) != nil else { return nil }
        var components = URLComponents(string: "https://www.apple.com.cn")!
        components.path = "/shop/product/" + sku
        return components.url
    }

    /// Extract JSON without evaluating JavaScript; braces in strings do not end the payload.
    static func selectionData(in html: String) -> Data? {
        guard let bootstrap = html.range(of: "window.PRODUCT_SELECTION_BOOTSTRAP"),
              let marker = html.range(of: "productSelectionData:", range: bootstrap.upperBound..<html.endIndex),
              let start = html[marker.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var quoted = false
        var escaped = false
        for index in html[start...].indices {
            let character = html[index]
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" { quoted = true }
            else if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 { return Data(html[start...index].utf8) }
            }
        }
        return nil
    }

    /// Match the exact SKU before selecting its product image (never the first variant).
    static func productImageURL(in html: String, product: String) -> URL? {
        guard let data = selectionData(in: html),
              let selection = try? JSONDecoder().decode(Selection.self, from: data),
              let item = selection.products.first(where: {
                  $0.partNumber.caseInsensitiveCompare(product.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
              }), let key = item.imageKey,
              let sources = selection.imageDictionary[key]?.sources else { return nil }
        return sources.compactMap { source in
            guard let first = source.srcSet.split(separator: ",").first?.split(whereSeparator: { $0.isWhitespace }).first,
                  let url = URL(string: String(first)),
                  url.scheme == "https", url.host == "store.storeimages.cdn-apple.com" else { return nil }
            return url
        }.first
    }

    /// 192 pixels supplies up to 3× resolution for the unchanged 64-point cell.
    static func thumbnailURL(for source: URL) -> URL? {
        guard source.host == "store.storeimages.cdn-apple.com", source.path.contains("/is/"),
              var components = URLComponents(url: source, resolvingAgainstBaseURL: false) else { return nil }
        // The original .v rendition token did not work with changed dimensions in live checks.
        components.queryItems = (components.queryItems ?? []).filter {
            !["wid", "hei", "fmt", "qlt", ".v"].contains($0.name)
        } + [URLQueryItem(name: "wid", value: "192"), URLQueryItem(name: "hei", value: "192"),
             URLQueryItem(name: "fmt", value: "png-alpha")]
        return components.url
    }

    private struct Selection: Decodable {
        struct Product: Decodable { let partNumber: String; let imageKey: String? }
        struct ProductImage: Decodable {
            struct Source: Decodable { let srcSet: String }
            let sources: [Source]
        }
        let products: [Product]
        let imageDictionary: [String: ProductImage]
    }

    static func imageURL(in html: String) -> URL? {
        let tags = try! NSRegularExpression(pattern: #"<meta\b[^>]*>"#, options: .caseInsensitive)
        let attributes = try! NSRegularExpression(pattern: #"([\w:-]+)\s*=\s*["']([^"']*)["']"#, options: .caseInsensitive)
        for match in tags.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])
            var values: [String: String] = [:]
            for attribute in attributes.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
                guard let key = Range(attribute.range(at: 1), in: tag), let value = Range(attribute.range(at: 2), in: tag) else { continue }
                values[String(tag[key]).lowercased()] = String(tag[value])
            }
            guard values["property"]?.lowercased() == "og:image", let content = values["content"] else { continue }
            let decoded = content.replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&#38;", with: "&").replacingOccurrences(of: "&#x26;", with: "&")
            guard let url = URL(string: decoded), url.scheme == "https", let host = url.host?.lowercased(),
                  host == "apple.com" || host.hasSuffix(".apple.com") || host.hasSuffix(".cdn-apple.com") else { continue }
            return url
        }
        return nil
    }
}

/// Product metadata is independent of stock polling; image failures must never fail a scan.
