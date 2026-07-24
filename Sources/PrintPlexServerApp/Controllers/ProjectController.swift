import Vapor
import Fluent
import PrintPlexCore

struct ProjectUpdateRequest: Content {
    var name: String?
    var projectDescription: String?
    var category: String?
    var creator: String?
    var tags: [String]?
    var suggestedMaterials: [String]?
    var multiColor: Bool?
    var notes: String?
    var shopifyProductId: String?
    var coverImageFileName: String?
}

struct ShopifyMatchResponse: Content {
    var product: ShopifyProduct
    var url: String?
}

struct ProjectController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let projects = routes.grouped("api", "projects")
        projects.get(use: index)
        projects.group(":projectID") { project in
            project.get(use: detail)
            project.patch(use: update)
            project.get("estimate", use: estimate)
            project.get("shopify", use: shopifyMatch)
        }
    }

    @Sendable
    func index(req: Request) async throws -> [ProjectDTO] {
        let models = try await ProjectModel.query(on: req.db)
            .sort(\.$lastModifiedAt, .descending)
            .all()
        return models.map { $0.toDTO() }
    }

    @Sendable
    func detail(req: Request) async throws -> ProjectDTO {
        let model = try await find(req)
        let files = try await FileModel.query(on: req.db)
            .filter(\.$project.$id == model.requireID())
            .sort(\.$fileName)
            .all()
        return model.toDTO(files: files.map { $0.toDTO() })
    }

    /// Updates project metadata in the DB **and** in the folder's info.json,
    /// so the library stays the source of truth for the next scan.
    @Sendable
    func update(req: Request) async throws -> ProjectDTO {
        let model = try await find(req)
        let body = try req.content.decode(ProjectUpdateRequest.self)

        if let v = body.name { model.name = v }
        if let v = body.projectDescription { model.projectDescription = v }
        if let v = body.category { model.category = v }
        if let v = body.creator { model.creator = v }
        if let v = body.tags { model.tags = v }
        if let v = body.suggestedMaterials { model.suggestedMaterials = v }
        if let v = body.multiColor { model.multiColor = v }
        if let v = body.notes { model.notes = v }
        if let v = body.shopifyProductId { model.shopifyProductId = v }
        if let v = body.coverImageFileName { model.coverImageFileName = v }
        try await model.save(on: req.db)

        try LibraryScanner.updateProjectInfo(in: model.folderPath) { info in
            if let v = body.name { info.nom = v }
            if let v = body.projectDescription { info.description = v }
            if let v = body.category { info.categorie = v }
            if let v = body.creator { info.createur = v }
            if let v = body.tags { info.tags = v }
            if let v = body.suggestedMaterials { info.materiaux_suggeres = v }
            if let v = body.multiColor { info.multi_couleur = v }
            if let v = body.notes { info.notes = v }
            if let v = body.shopifyProductId { info.shopify_product_id = v }
            if let v = body.coverImageFileName { info.image_principale = v }
        }

        return model.toDTO()
    }

    /// Combined estimate over every 3MF part that has parsed mesh stats.
    @Sendable
    func estimate(req: Request) async throws -> PrintEstimate {
        let model = try await find(req)
        let files = try await FileModel.query(on: req.db)
            .filter(\.$project.$id == model.requireID())
            .all()

        let (printer, material, settings, manual) = try EstimateSupport.inputs(from: req)

        let estimates = files.compactMap { file -> PrintEstimate? in
            guard file.fileRole == .modelPart, let stats = file.meshStats else { return nil }
            return PrintEstimator.estimate(
                parsed: EstimateSupport.parserResult(from: stats),
                printer: printer, material: material, settings: settings
            )
        }
        guard !estimates.isEmpty else {
            throw Abort(.conflict, reason: "Aucune pièce avec statistiques de maillage — lancez un scan d'abord")
        }

        let base = PrintEstimator.total(estimates: estimates, printer: printer, material: material)
        guard manual != .aucun else { return base }
        // Manual work applies once per project, not per part
        return PrintEstimate(
            filamentLengthM: base.filamentLengthM,
            filamentWeightG: base.filamentWeightG,
            printTimeSeconds: base.printTimeSeconds,
            layerCount: base.layerCount,
            fitsOnBed: base.fitsOnBed,
            printerName: base.printerName,
            materialName: base.materialName,
            filamentCostEur: base.filamentCostEur,
            timeCostEur: base.timeCostEur,
            manualCostEur: manual.cost
        )
    }

    @Sendable
    func shopifyMatch(req: Request) async throws -> ShopifyMatchResponse {
        guard let cache = req.application.shopifyCache else {
            throw Abort(.serviceUnavailable, reason: "Shopify non configuré (SHOPIFY_STORE_DOMAIN / SHOPIFY_ACCESS_TOKEN)")
        }
        let model = try await find(req)
        _ = try await cache.productsSyncingIfNeeded()
        guard let product = await cache.match(projectName: model.name,
                                              explicitProductId: model.shopifyProductId) else {
            throw Abort(.notFound, reason: "Aucun produit Shopify correspondant")
        }
        return ShopifyMatchResponse(product: product,
                                    url: cache.url(for: product)?.absoluteString)
    }

    private func find(_ req: Request) async throws -> ProjectModel {
        guard let id = req.parameters.get("projectID", as: UUID.self),
              let model = try await ProjectModel.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Projet introuvable")
        }
        return model
    }
}
