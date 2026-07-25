import Vapor
import Fluent
import PrintPlexCore

struct EstimateQuery: Content {
    var printerId: UUID?
    var materialId: UUID?
    var layerHeightMM: Double?
    var shellCount: Int?
    var infillPercent: Int?
    var manualWork: String?
}

enum EstimateSupport {
    /// Printers and materials are user-editable via the settings API
    /// (PrinterModel/MaterialModel) — this looks them up by id, falling back
    /// to the first configured one (by sortOrder) when none is specified.
    static func inputs(from req: Request) async throws
        -> (PrinterProfile, PrintMaterial, PrintSettings, ManualWorkLevel) {
        let query = try req.query.decode(EstimateQuery.self)

        let printerModel: PrinterModel?
        if let id = query.printerId {
            printerModel = try await PrinterModel.find(id, on: req.db)
        } else {
            printerModel = try await PrinterModel.query(on: req.db).sort(\.$sortOrder).first()
        }
        guard let printerModel else {
            throw Abort(.notFound, reason: "Imprimante inconnue")
        }

        let materialModel: MaterialModel?
        if let id = query.materialId {
            materialModel = try await MaterialModel.find(id, on: req.db)
        } else {
            materialModel = try await MaterialModel.query(on: req.db).sort(\.$sortOrder).first()
        }
        guard let materialModel else {
            throw Abort(.notFound, reason: "Matériau inconnu")
        }

        var settings = PrintSettings()
        if let v = query.layerHeightMM { settings.layerHeightMM = v }
        if let v = query.shellCount { settings.shellCount = v }
        if let v = query.infillPercent { settings.infillPercent = v }

        let manual = query.manualWork.flatMap(ManualWorkLevel.init(rawValue:)) ?? .aucun
        return (printerModel.toDTO(), materialModel.toDTO(), settings, manual)
    }

    static func parserResult(from stats: MeshStatsDTO) -> ThreeMFParser.Result {
        ThreeMFParser.Result(
            volumeMM3: stats.volumeMM3,
            surfaceAreaMM2: stats.surfaceAreaMM2,
            widthMM: stats.widthMM,
            heightMM: stats.heightMM,
            depthMM: stats.depthMM,
            triangleCount: stats.triangles,
            vertexCount: stats.vertexCount,
            plateCount: stats.plateCount
        )
    }
}
