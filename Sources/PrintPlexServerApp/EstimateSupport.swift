import Vapor
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
    /// Printers and materials are the package defaults for now — per-user
    /// profiles move server-side in a later phase.
    static func inputs(from req: Request) throws
        -> (PrinterProfile, PrintMaterial, PrintSettings, ManualWorkLevel) {
        let query = try req.query.decode(EstimateQuery.self)

        let printer: PrinterProfile
        if let id = query.printerId {
            guard let found = PrinterProfile.defaults.first(where: { $0.id == id }) else {
                throw Abort(.notFound, reason: "Imprimante inconnue")
            }
            printer = found
        } else {
            printer = PrinterProfile.defaults[0]
        }

        let material: PrintMaterial
        if let id = query.materialId {
            guard let found = PrintMaterial.defaults.first(where: { $0.id == id }) else {
                throw Abort(.notFound, reason: "Matériau inconnu")
            }
            material = found
        } else {
            material = PrintMaterial.defaults[0]
        }

        var settings = PrintSettings()
        if let v = query.layerHeightMM { settings.layerHeightMM = v }
        if let v = query.shellCount { settings.shellCount = v }
        if let v = query.infillPercent { settings.infillPercent = v }

        let manual = query.manualWork.flatMap(ManualWorkLevel.init(rawValue:)) ?? .aucun
        return (printer, material, settings, manual)
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
