import Fluent
import Foundation
import PrintPlexCore

/// DB-backed material catalog — seeded once from `PrintMaterial.defaults`.
/// Mirrors the macOS app's behavior: the catalog itself is fixed, only the
/// price per kg is editable from Settings.
final class MaterialModel: Model, @unchecked Sendable {
    static let schema = "materials"

    @ID(key: .id) var id: UUID?
    @Field(key: "name") var name: String
    @Field(key: "density_g_cm3") var densityGCM3: Double
    @Field(key: "price_per_kg") var pricePerKg: Double
    @Field(key: "sort_order") var sortOrder: Int

    init() {}

    convenience init(from material: PrintMaterial, sortOrder: Int) {
        self.init()
        self.id = material.id
        self.name = material.name
        self.densityGCM3 = material.densityGCM3
        self.pricePerKg = material.pricePerKg
        self.sortOrder = sortOrder
    }

    func toDTO() -> PrintMaterial {
        PrintMaterial(id: id ?? UUID(), name: name, densityGCM3: densityGCM3, pricePerKg: pricePerKg)
    }
}
