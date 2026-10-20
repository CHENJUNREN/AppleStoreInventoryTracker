import Foundation

// Only the pickup response is modeled; delivery and reservation flows are outside this app.
struct PickupAPIModel: Decodable {
    let head: Head?
    let body: Body
    struct Head: Decodable {
        let status: Int?
        enum CodingKeys: String, CodingKey { case status }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.status), try !container.decodeNil(forKey: .status) else {
                status = nil
                return
            }
            if let number = try? container.decode(Int.self, forKey: .status) {
                status = number
            } else {
                let text = try container.decode(String.self, forKey: .status)
                guard let number = Int(text) else {
                    throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "Invalid pickup status")
                }
                status = number
            }
        }
    }
    struct Body: Decodable { let stores: [Store] }
    struct Store: Decodable {
        let storeNumber: String?
        let storeName: String
        let storeImageUrl: String?
        let partsAvailability: [String: Part]
    }
    struct Part: Decodable {
        let partNumber: String?
        let pickupDisplay: String?
        let storePickEligible: Bool?
        let messageTypes: MessageTypes?
    }
    struct MessageTypes: Decodable { let regular: Regular? }
    struct Regular: Decodable { let storePickupProductTitle: String? }
}
