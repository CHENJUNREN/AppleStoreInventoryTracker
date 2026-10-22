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
    var barkURL: String?
    var customizationEnabled: Bool?
    var purchase: TaskPurchaseSettings?

    func resolved(using defaults: ScanDefaults) -> ScanDefaults {
        var result = defaults
        result.region = region ?? defaults.region
        result.interval = interval ?? defaults.interval
        result.appNotification = appNotification ?? defaults.appNotification
        result.barkNotification = barkNotification ?? defaults.barkNotification
        result.barkURL = barkURL ?? defaults.barkURL
        return result
    }
    /// Resolve legacy optional fields once; saved tasks own a complete configuration snapshot.
    func frozen(using defaults: ScanDefaults) -> ScanTask {
        var task = configured(with: resolved(using: defaults))
        if task.customizationEnabled == nil {
            task.customizationEnabled = task.resolved(using: defaults) != defaults
        }
        return task
    }

    func configured(with settings: ScanDefaults) -> ScanTask {
        var task = self
        task.region = settings.region
        task.interval = settings.interval
        task.appNotification = settings.appNotification
        task.barkNotification = settings.barkNotification
        task.barkURL = settings.barkURL
        return task
    }

    var normalizedProduct: String { product.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
}

/// Editor state is separate from the saved snapshot until the user chooses Save.
struct ScanTaskDraft {
    var task: ScanTask
    var settings: ScanDefaults
    private(set) var customizationEnabled: Bool

    init(task: ScanTask, defaults: ScanDefaults) {
        self.task = task
        settings = task.resolved(using: defaults)
        customizationEnabled = task.customizationEnabled ?? (settings != defaults)
    }

    mutating func setCustomizationEnabled(_ enabled: Bool, defaults: ScanDefaults) {
        customizationEnabled = enabled
        if !enabled { settings = defaults }
    }

    var savedTask: ScanTask {
        var result = task.configured(with: settings)
        result.customizationEnabled = customizationEnabled
        return result
    }
}
