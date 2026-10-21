import Foundation

struct IPhoneVariant: Codable, Equatable, Identifiable {
    let partNumber: String
    let modelID: String
    let modelName: String
    let colorID: String
    let color: String
    let capacityID: String
    let capacity: String
    let imageURL: URL?
    var id: String { partNumber }
    var displayName: String { "\(modelName) \(capacity) \(color)" }
}

struct IPhoneModel: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let variants: [IPhoneVariant]
}

struct IPhoneCatalog: Codable, Equatable {
    let updatedAt: Date
    let models: [IPhoneModel]
}

/// Resolve only actual combinations published by Apple, never synthesize a part number.
struct IPhoneSelection: Equatable {
    var modelID = ""
    var colorID = ""
    var capacityID = ""

    func variant(in catalog: IPhoneCatalog?) -> IPhoneVariant? {
        let matches = catalog?.models.first { $0.id == modelID }?.variants.filter {
            $0.colorID == colorID && $0.capacityID == capacityID
        } ?? []
        return matches.count == 1 ? matches[0] : nil
    }

    mutating func selectModel(_ id: String) {
        modelID = id
        colorID = ""
        capacityID = ""
    }

    mutating func selectColor(_ id: String, in catalog: IPhoneCatalog?) {
        colorID = id
        if variant(in: catalog) == nil { capacityID = "" }
    }
}
