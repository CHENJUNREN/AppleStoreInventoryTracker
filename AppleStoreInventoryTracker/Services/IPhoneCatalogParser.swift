import Foundation

enum IPhoneCatalogError: LocalizedError {
    case invalidPage
    case emptyCatalog
    case httpStatus(Int)
    case coolingDown

    var errorDescription: String? {
        switch self {
        case .invalidPage: "暂时无法读取官网商品数据，请稍后重试。"
        case .emptyCatalog: "暂未获取到在售 iPhone，请稍后重试。"
        case .httpStatus(let code): "商品目录获取失败（HTTP \(code)），请稍后重试。"
        case .coolingDown: "请稍后再刷新商品目录。"
        }
    }
}

enum IPhoneCatalogParser {
    /// Only product cards on the current shop index, not recommendation or accessory links.
    static func productPages(in html: String) throws -> [URL] {
        let tags = matches(#"<a\b[^>]*>"#, in: html)
        var seen = Set<URL>()
        let urls = tags.compactMap { tag -> URL? in
            let attrs = attributes(in: tag)
            guard let part = attrs["data-part-number"], part.hasPrefix("IPHONE"), part.hasSuffix("_MAIN"),
                  let href = attrs["href"],
                  let url = URL(string: decodeEntities(href), relativeTo: URL(string: "https://www.apple.com.cn")!)?.absoluteURL,
                  url.scheme == "https", url.host == "www.apple.com.cn", url.query == nil,
                  url.path.range(of: #"^/shop/buy-iphone/iphone-[a-z0-9-]+$"#, options: .regularExpression) != nil,
                  seen.insert(url).inserted else { return nil }
            return url
        }
        guard !urls.isEmpty, urls.count <= 20 else { throw IPhoneCatalogError.emptyCatalog }
        return urls
    }

    static func models(in html: String) throws -> [IPhoneModel] {
        guard let data = AppleProductPage.selectionData(in: html),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let products = root["products"] as? [[String: Any]],
              let display = root["displayValues"] as? [String: Any] else { throw IPhoneCatalogError.invalidPage }
        let images = root["imageDictionary"] as? [String: [String: Any]] ?? [:]
        let fallbackName = matches(#"<meta\b[^>]*>"#, in: html).compactMap { tag -> String? in
            let attrs = attributes(in: tag)
            guard attrs["property"] == "og:title", let title = attrs["content"] else { return nil }
            let clean = plainText(title)
            guard let range = clean.range(of: "iPhone") else { return nil }
            return String(clean[range.lowerBound...])
        }.first
        var grouped: [String: [IPhoneVariant]] = [:]
        var order: [String] = []
        var seen = Set<String>()
        for item in products {
            if item["comingSoon"] as? Bool == true || item["getReady"] as? Bool == true || item["isCarrierDevice"] as? Bool == true { continue }
            guard let sku = item["partNumber"] as? String,
                  sku.range(of: #"^[A-Za-z0-9]+CH/A$"#, options: .regularExpression) != nil,
                  let family = item["familyType"] as? String, family.hasPrefix("iphone"),
                  let colorID = item["dimensionColor"] as? String,
                  let capacityID = item["dimensionCapacity"] as? String,
                  let color = value(colorID, dimension: "dimensionColor", in: display),
                  let capacity = value(capacityID, dimension: "dimensionCapacity", in: display) else {
                throw IPhoneCatalogError.invalidPage
            }
            let screen = item["dimensionScreensize"] as? String
            let name = screen.flatMap { value($0, dimension: "dimensionScreensize", in: display) } ?? fallbackName
            guard let name, name.hasPrefix("iPhone"), !name.contains("和"), !color.isEmpty, !capacity.isEmpty else {
                throw IPhoneCatalogError.invalidPage
            }
            guard seen.insert(sku.uppercased()).inserted else { continue }
            let image = (item["imageKey"] as? String).flatMap { images[$0] }
            let sources = image?["sources"] as? [[String: Any]] ?? []
            let imageURL = sources.compactMap { source -> URL? in
                guard let src = source["srcSet"] as? String,
                      let first = src.split(separator: ",").first?.split(whereSeparator: { $0.isWhitespace }).first,
                      let url = URL(string: String(first)), url.scheme == "https",
                      url.host == "store.storeimages.cdn-apple.com" else { return nil }
                return url
            }.first
            if grouped[family] == nil { order.append(family) }
            grouped[family, default: []].append(IPhoneVariant(partNumber: sku.uppercased(), modelID: family,
                modelName: name, colorID: colorID, color: color, capacityID: capacityID, capacity: capacity, imageURL: imageURL))
        }
        guard !order.isEmpty else { throw IPhoneCatalogError.emptyCatalog }
        let screenOrder = dimensionOrder("dimensionScreensize", in: display)
        let colorOrder = dimensionOrder("dimensionColor", in: display)
        let capacityOrder = dimensionOrder("dimensionCapacity", in: display)
        // Preserve the page's configured model/color/capacity ordering instead of JSON dictionary order.
        let familyOrder = screenOrder.compactMap { screen in
            products.first(where: { $0["dimensionScreensize"] as? String == screen })?["familyType"] as? String
        }
        order.sort { rank($0, in: familyOrder) < rank($1, in: familyOrder) }
        return try order.map { family in
            let variants = grouped[family]!.sorted {
                let left = (rank($0.colorID, in: colorOrder), rank($0.capacityID, in: capacityOrder), $0.partNumber)
                let right = (rank($1.colorID, in: colorOrder), rank($1.capacityID, in: capacityOrder), $1.partNumber)
                return left < right
            }
            let combos = Set(variants.map { "\($0.colorID)|\($0.capacityID)" })
            guard combos.count == variants.count else { throw IPhoneCatalogError.invalidPage }
            return IPhoneModel(id: family, name: variants[0].modelName, variants: variants)
        }
    }

    private static func dimensionOrder(_ dimension: String, in display: [String: Any]) -> [String] {
        (display[dimension] as? [String: Any])?["variantOrder"] as? [String] ?? []
    }

    private static func rank(_ id: String, in order: [String]) -> Int { order.firstIndex(of: id) ?? Int.max }

    private static func value(_ id: String, dimension: String, in display: [String: Any]) -> String? {
        guard let values = display[dimension] as? [String: Any],
              let entry = values[id] as? [String: Any], let raw = entry["value"] as? String else { return nil }
        // Screen-size detail and footnotes are not part of a model or capacity label.
        let firstLine = raw.components(separatedBy: "\n")[0]
        return plainText(firstLine.replacingOccurrences(of: #"<as-footnote\b[^>]*>[\s\S]*?</as-footnote>"#, with: "", options: .regularExpression))
    }

    private static func plainText(_ html: String) -> String {
        decodeEntities(html.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression))
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, value) in [("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&#160;", " ")] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func attributes(in tag: String) -> [String: String] {
        let regex = try! NSRegularExpression(pattern: #"([\w:-]+)\s*=\s*["']([^"']*)["']"#)
        var result: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            if let key = Range(match.range(at: 1), in: tag), let value = Range(match.range(at: 2), in: tag) {
                result[String(tag[key]).lowercased()] = String(tag[value])
            }
        }
        return result
    }
}
