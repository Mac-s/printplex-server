import Vapor
import Fluent
import PrintPlexCore

struct MaterialUpdateRequest: Content {
    var pricePerKg: Double
}

/// The material catalog is fixed (mirrors the macOS app's "Matériel" tab) —
/// only the price per kg is editable.
struct MaterialController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let materials = routes.grouped("api", "materials")
        materials.get(use: index)
        materials.group(":materialID") { material in
            material.patch(use: update)
        }
    }

    @Sendable
    func index(req: Request) async throws -> [PrintMaterial] {
        try await Self.fetchIndex(on: req.db)
    }

    static func fetchIndex(on db: Database) async throws -> [PrintMaterial] {
        try await MaterialModel.query(on: db).sort(\.$sortOrder).all().map { $0.toDTO() }
    }

    @Sendable
    func update(req: Request) async throws -> PrintMaterial {
        guard let id = req.parameters.get("materialID", as: UUID.self) else {
            throw Abort(.notFound, reason: "Matériau introuvable")
        }
        let body = try req.content.decode(MaterialUpdateRequest.self)
        return try await Self.applyUpdate(body, id: id, on: req.db)
    }

    static func applyUpdate(_ body: MaterialUpdateRequest, id: UUID, on db: Database) async throws -> PrintMaterial {
        guard let model = try await MaterialModel.find(id, on: db) else {
            throw Abort(.notFound, reason: "Matériau introuvable")
        }
        guard body.pricePerKg > 0 else {
            throw Abort(.badRequest, reason: "Le prix doit être positif")
        }
        model.pricePerKg = body.pricePerKg
        try await model.save(on: db)
        return model.toDTO()
    }
}
