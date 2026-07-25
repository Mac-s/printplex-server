import Vapor
import Fluent
import PrintPlexCore

struct PrinterUpsertRequest: Content {
    var name: String
    var buildX: Double
    var buildY: Double
    var buildZ: Double
    var perimeterSpeedMMPS: Double
    var infillSpeedMMPS: Double
    var nozzleDiameterMM: Double
    var defaultLayerHeightMM: Double
    var supportsPercent: Double
    var purgePercent: Double
    var speedEfficiency: Double
}

struct PrinterUpdateRequest: Content {
    var name: String?
    var buildX: Double?
    var buildY: Double?
    var buildZ: Double?
    var perimeterSpeedMMPS: Double?
    var infillSpeedMMPS: Double?
    var nozzleDiameterMM: Double?
    var defaultLayerHeightMM: Double?
    var supportsPercent: Double?
    var purgePercent: Double?
    var speedEfficiency: Double?
}

/// CRUD for printer profiles — mirrors the "Matériel" tab of the macOS app's
/// Settings window (add / edit / remove printers).
struct PrinterController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let printers = routes.grouped("api", "printers")
        printers.get(use: index)
        printers.post(use: create)
        printers.group(":printerID") { printer in
            printer.patch(use: update)
            printer.delete(use: delete)
        }
    }

    @Sendable
    func index(req: Request) async throws -> [PrinterProfile] {
        try await PrinterModel.query(on: req.db).sort(\.$sortOrder).all().map { $0.toDTO() }
    }

    @Sendable
    func create(req: Request) async throws -> PrinterProfile {
        let body = try req.content.decode(PrinterUpsertRequest.self)
        let maxOrder = try await PrinterModel.query(on: req.db).max(\.$sortOrder) ?? -1

        let model = PrinterModel()
        model.id = UUID()
        model.name = body.name
        model.buildX = body.buildX
        model.buildY = body.buildY
        model.buildZ = body.buildZ
        model.perimeterSpeedMMPS = body.perimeterSpeedMMPS
        model.infillSpeedMMPS = body.infillSpeedMMPS
        model.nozzleDiameterMM = body.nozzleDiameterMM
        model.defaultLayerHeightMM = body.defaultLayerHeightMM
        model.supportsPercent = body.supportsPercent
        model.purgePercent = body.purgePercent
        model.speedEfficiency = body.speedEfficiency
        model.sortOrder = maxOrder + 1
        try await model.save(on: req.db)
        return model.toDTO()
    }

    @Sendable
    func update(req: Request) async throws -> PrinterProfile {
        let model = try await find(req)
        let body = try req.content.decode(PrinterUpdateRequest.self)

        if let v = body.name { model.name = v }
        if let v = body.buildX { model.buildX = v }
        if let v = body.buildY { model.buildY = v }
        if let v = body.buildZ { model.buildZ = v }
        if let v = body.perimeterSpeedMMPS { model.perimeterSpeedMMPS = v }
        if let v = body.infillSpeedMMPS { model.infillSpeedMMPS = v }
        if let v = body.nozzleDiameterMM { model.nozzleDiameterMM = v }
        if let v = body.defaultLayerHeightMM { model.defaultLayerHeightMM = v }
        if let v = body.supportsPercent { model.supportsPercent = v }
        if let v = body.purgePercent { model.purgePercent = v }
        if let v = body.speedEfficiency { model.speedEfficiency = v }
        try await model.save(on: req.db)
        return model.toDTO()
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let model = try await find(req)
        try await model.delete(on: req.db)
        return .noContent
    }

    private func find(_ req: Request) async throws -> PrinterModel {
        guard let id = req.parameters.get("printerID", as: UUID.self),
              let model = try await PrinterModel.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Imprimante introuvable")
        }
        return model
    }
}
