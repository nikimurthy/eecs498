import Foundation

struct Chatt: Identifiable, Hashable {
    var name: String?
    var message: String?
    var id: UUID?
    var timestamp: String?
    var geodata: GeoData?
    
    // so that we don't need to compare every property for equality
    static func ==(lhs: Chatt, rhs: Chatt) -> Bool {
        lhs.id == rhs.id
    }
}

