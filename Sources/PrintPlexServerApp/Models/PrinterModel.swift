import Fluent
import Foundation
import PrintPlexCore

/// DB-backed printer profiles — seeded once from `PrinterProfile.defaults`,
/// then fully editable (add/edit/remove) via the settings API.
final class PrinterModel: Model, @unchecked Sendable {
    static let schema = "printers"

    @ID(key: .id) var id: UUID?
    @Field(key: "name") var name: String
    @Field(key: "build_x") var buildX: Double
    @Field(key: "build_y") var buildY: Double
    @Field(key: "build_z") var buildZ: Double
    @Field(key: "perimeter_speed_mmps") var perimeterSpeedMMPS: Double
    @Field(key: "infill_speed_mmps") var infillSpeedMMPS: Double
    @Field(key: "nozzle_diameter_mm") var nozzleDiameterMM: Double
    @Field(key: "default_layer_height_mm") var defaultLayerHeightMM: Double
    @Field(key: "supports_percent") var supportsPercent: Double
    @Field(key: "purge_percent") var purgePercent: Double
    @Field(key: "speed_efficiency") var speedEfficiency: Double
    /// Preserves the seed order (and lets new printers append at the end)
    /// since SQLite doesn't guarantee row order without an explicit sort.
    @Field(key: "sort_order") var sortOrder: Int

    init() {}

    convenience init(from profile: PrinterProfile, sortOrder: Int) {
        self.init()
        self.id = profile.id
        apply(profile, sortOrder: sortOrder)
    }

    func apply(_ profile: PrinterProfile, sortOrder: Int? = nil) {
        name = profile.name
        buildX = profile.buildX
        buildY = profile.buildY
        buildZ = profile.buildZ
        perimeterSpeedMMPS = profile.perimeterSpeedMMPS
        infillSpeedMMPS = profile.infillSpeedMMPS
        nozzleDiameterMM = profile.nozzleDiameterMM
        defaultLayerHeightMM = profile.defaultLayerHeightMM
        supportsPercent = profile.supportsPercent
        purgePercent = profile.purgePercent
        speedEfficiency = profile.speedEfficiency
        if let sortOrder { self.sortOrder = sortOrder }
    }

    func toDTO() -> PrinterProfile {
        PrinterProfile(
            id: id ?? UUID(),
            name: name,
            buildX: buildX, buildY: buildY, buildZ: buildZ,
            perimeterSpeedMMPS: perimeterSpeedMMPS,
            infillSpeedMMPS: infillSpeedMMPS,
            nozzleDiameterMM: nozzleDiameterMM,
            defaultLayerHeightMM: defaultLayerHeightMM,
            supportsPercent: supportsPercent,
            purgePercent: purgePercent,
            speedEfficiency: speedEfficiency
        )
    }
}
