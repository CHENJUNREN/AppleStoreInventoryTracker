import Foundation

struct ScanRegion: Codable, Equatable {
    var province = "重庆"
    var city = "重庆"
    var district = "九龙坡区"
    var location: String { [province, city, district].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ") }
    var isValid: Bool { [province, city, district].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}

struct ScanDefaults: Codable, Equatable {
    var region = ScanRegion()
    var interval = 60
    var appNotification = true
    var barkNotification = false
    var barkURL = ""
    var isValid: Bool { region.isValid && interval > 0 && interval <= Int(Int32.max) }
}

struct ScanTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var product = ""
    var name = ""
    var region: ScanRegion?
    var interval: Int?
    var appNotification: Bool?
    var barkNotification: Bool?

    func resolved(using defaults: ScanDefaults) -> ScanDefaults {
        var result = defaults
        result.region = region ?? defaults.region
        result.interval = interval ?? defaults.interval
        result.appNotification = appNotification ?? defaults.appNotification
        result.barkNotification = barkNotification ?? defaults.barkNotification
        return result
    }
    var normalizedProduct: String { product.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
}
