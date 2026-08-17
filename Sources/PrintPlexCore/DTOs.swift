import Foundation

// MARK: - API DTOs
// Plain Codable mirrors of the app's SwiftData models. These will be the
// wire format between the server and its clients (macOS, iOS, web).

public struct MeshStatsDTO: Codable, Sendable, Equatable {
    public var triangles: Int
    public var widthMM: Double
    public var heightMM: Double
    public var depthMM: Double
    public var volumeMM3: Double
    public var surfaceAreaMM2: Double
    public var vertexCount: Int
    public var parsedAt: Date?
    /// Number of print plates detected in the file (1 for standard 3MF).
    public var plateCount: Int
    /// Which plate (0-based) these particular stats describe. Always 0 for standard
    /// 3MF files; for multi-plate BambuStudio files, `FileModel.plateStats` holds one
    /// entry per plate, each with its own `plateIndex`.
    public var plateIndex: Int

    public init(triangles: Int, widthMM: Double, heightMM: Double, depthMM: Double,
                volumeMM3: Double, surfaceAreaMM2: Double = 0, vertexCount: Int = 0,
                parsedAt: Date? = nil, plateCount: Int = 1, plateIndex: Int = 0) {
        self.triangles = triangles
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.depthMM = depthMM
        self.volumeMM3 = volumeMM3
        self.surfaceAreaMM2 = surfaceAreaMM2
        self.vertexCount = vertexCount
        self.parsedAt = parsedAt
        self.plateCount = plateCount
        self.plateIndex = plateIndex
    }

    public init(from result: ThreeMFParser.Result, parsedAt: Date? = nil) {
        self.init(triangles: result.triangleCount,
                  widthMM: result.widthMM,
                  heightMM: result.heightMM,
                  depthMM: result.depthMM,
                  volumeMM3: result.volumeMM3,
                  surfaceAreaMM2: result.surfaceAreaMM2,
                  vertexCount: result.vertexCount,
                  parsedAt: parsedAt,
                  plateCount: result.plateCount,
                  plateIndex: result.plateIndex)
    }

    enum CodingKeys: String, CodingKey {
        case triangles, widthMM, heightMM, depthMM, volumeMM3, surfaceAreaMM2
        case vertexCount, parsedAt, plateCount, plateIndex
    }

    // Custom decode so rows cached before `plateIndex` existed (or before
    // surfaceAreaMM2/vertexCount/plateCount) still load — same pattern as
    // PrinterProfile's decodeIfPresent fallbacks in PrintEstimator.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        triangles      = try c.decode(Int.self, forKey: .triangles)
        widthMM        = try c.decode(Double.self, forKey: .widthMM)
        heightMM       = try c.decode(Double.self, forKey: .heightMM)
        depthMM        = try c.decode(Double.self, forKey: .depthMM)
        volumeMM3      = try c.decode(Double.self, forKey: .volumeMM3)
        surfaceAreaMM2 = try c.decodeIfPresent(Double.self, forKey: .surfaceAreaMM2) ?? 0
        vertexCount    = try c.decodeIfPresent(Int.self, forKey: .vertexCount) ?? 0
        parsedAt       = try c.decodeIfPresent(Date.self, forKey: .parsedAt)
        plateCount     = try c.decodeIfPresent(Int.self, forKey: .plateCount) ?? 1
        plateIndex     = try c.decodeIfPresent(Int.self, forKey: .plateIndex) ?? 0
    }
}

public struct PrintParamsDTO: Codable, Sendable, Equatable {
    public var layerHeightMM: Double?
    public var nozzleTempC: Int?
    public var bedTempC: Int?
    public var material: String?
    public var estimatedTimeSec: Int?
    public var manualWorkLevel: String?
    /// Measured after actually printing (real slicer output / a scale at the
    /// printer) — takes priority over the geometry-based estimate for
    /// display once set, since it's the real value rather than a guess.
    public var actualPrintTimeSec: Int?
    public var actualFilamentGrams: Double?

    public init(layerHeightMM: Double? = nil, nozzleTempC: Int? = nil, bedTempC: Int? = nil,
                material: String? = nil, estimatedTimeSec: Int? = nil, manualWorkLevel: String? = nil,
                actualPrintTimeSec: Int? = nil, actualFilamentGrams: Double? = nil) {
        self.layerHeightMM = layerHeightMM
        self.nozzleTempC = nozzleTempC
        self.bedTempC = bedTempC
        self.material = material
        self.estimatedTimeSec = estimatedTimeSec
        self.manualWorkLevel = manualWorkLevel
        self.actualPrintTimeSec = actualPrintTimeSec
        self.actualFilamentGrams = actualFilamentGrams
    }
}

public struct FileDTO: Codable, Sendable, Identifiable {
    public var id: UUID
    public var path: String
    public var fileName: String
    public var fileExtension: String
    public var fileSize: Int64
    public var createdAt: Date
    public var modifiedAt: Date
    public var contentHash: String?
    public var kind: FileKind
    public var fileRole: FileRole
    public var tags: [String]
    public var cloudStatus: CloudStatus
    public var sourceApp: String?
    public var meshStats: MeshStatsDTO?
    /// Populated only when the file has more than one print plate (BambuStudio project
    /// files) — one entry per plate, each carrying its own `plateIndex`. `meshStats` above
    /// always mirrors the plateIndex == 0 entry for backward compatibility with clients
    /// that only look at a single result.
    public var plateStats: [MeshStatsDTO]?
    public var printParams: PrintParamsDTO?

    public init(id: UUID = UUID(), path: String, fileName: String, fileExtension: String,
                fileSize: Int64, createdAt: Date, modifiedAt: Date, contentHash: String? = nil,
                kind: FileKind, fileRole: FileRole = .other, tags: [String] = [],
                cloudStatus: CloudStatus = .local, sourceApp: String? = nil,
                meshStats: MeshStatsDTO? = nil, plateStats: [MeshStatsDTO]? = nil,
                printParams: PrintParamsDTO? = nil) {
        self.id = id
        self.path = path
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.fileSize = fileSize
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.contentHash = contentHash
        self.kind = kind
        self.fileRole = fileRole
        self.tags = tags
        self.cloudStatus = cloudStatus
        self.sourceApp = sourceApp
        self.meshStats = meshStats
        self.plateStats = plateStats
        self.printParams = printParams
    }
}

public struct ProjectDTO: Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var folderPath: String
    /// `folderPath` with the container's media root swapped for the host
    /// path the user entered in Réglages ("Chemin local") — nil until
    /// that's configured, since the container has no way to know it itself.
    public var localFolderPath: String?
    public var lastModifiedAt: Date
    public var dateAdded: Date
    public var coverImageFileName: String?

    // info.json metadata
    public var projectDescription: String?
    public var category: String?
    public var creator: String?
    public var tags: [String]
    public var suggestedMaterials: [String]
    public var multiColor: Bool?
    public var notes: String?
    public var alreadyPrinted: Bool?
    /// Link back to the design's page on whatever site it came from.
    public var sourceUrl: String?
    /// Free-text hardware line items from the design's source (e.g. magnets).
    public var sourceHardware: [String]
    /// The design's own weight/print-time estimate — kept separate from
    /// PrintPlex's own computed `PrintEstimate`, not a substitute for it.
    public var sourceEstimatedWeight: String?
    public var sourceEstimatedPrintTime: String?
    /// Filenames of imported instruction images, matched against `files` by
    /// the dashboard to render them in their own section — excluded from
    /// the regular photo gallery and cover-image selection.
    public var sourceInstructionImages: [String]
    /// Set when the dashboard asks the ForgeCore relay (running on the
    /// user's own machine, where the authenticated scraping session lives)
    /// to scrape+import `sourceUrl` — "pending" while waiting on the relay,
    /// "failed" (with `sourceScrapeError`) if its last attempt didn't work.
    /// Deliberately DB-only, not part of `ProjectInfo`/info.json: this is
    /// transient job state, not descriptive data about the design.
    public var sourceScrapeStatus: String?
    public var sourceScrapeError: String?

    /// Shopify integration — explicit product ID override (nil = auto-match by name)
    public var shopifyProductId: String?

    /// Populated on detail endpoints; nil on list endpoints.
    public var files: [FileDTO]?

    // Precomputed by the server (from the project's files) so the grid view
    // can render cards without fetching each project's detail individually.
    public var coverFileId: UUID?
    public var partsCount: Int
    public var totalFileCount: Int
    public var imageCount: Int
    /// True once at least one 3MF file has real, measured print data (the
    /// "Impression réelle" block) — backs the "Estimé manuellement" sidebar
    /// filter. Precomputed like the counts above, from the same file set.
    public var hasManualEstimate: Bool

    public init(id: UUID = UUID(), name: String, folderPath: String, localFolderPath: String? = nil,
                lastModifiedAt: Date = Date(), dateAdded: Date = Date(),
                coverImageFileName: String? = nil, projectDescription: String? = nil,
                category: String? = nil, creator: String? = nil, tags: [String] = [],
                suggestedMaterials: [String] = [], multiColor: Bool? = nil,
                notes: String? = nil, alreadyPrinted: Bool? = nil,
                sourceUrl: String? = nil, sourceHardware: [String] = [],
                sourceEstimatedWeight: String? = nil, sourceEstimatedPrintTime: String? = nil,
                sourceInstructionImages: [String] = [],
                sourceScrapeStatus: String? = nil, sourceScrapeError: String? = nil,
                shopifyProductId: String? = nil,
                files: [FileDTO]? = nil, coverFileId: UUID? = nil,
                partsCount: Int = 0, totalFileCount: Int = 0, imageCount: Int = 0,
                hasManualEstimate: Bool = false) {
        self.id = id
        self.name = name
        self.folderPath = folderPath
        self.localFolderPath = localFolderPath
        self.lastModifiedAt = lastModifiedAt
        self.dateAdded = dateAdded
        self.coverImageFileName = coverImageFileName
        self.projectDescription = projectDescription
        self.category = category
        self.creator = creator
        self.tags = tags
        self.suggestedMaterials = suggestedMaterials
        self.multiColor = multiColor
        self.notes = notes
        self.alreadyPrinted = alreadyPrinted
        self.sourceUrl = sourceUrl
        self.sourceHardware = sourceHardware
        self.sourceEstimatedWeight = sourceEstimatedWeight
        self.sourceEstimatedPrintTime = sourceEstimatedPrintTime
        self.sourceInstructionImages = sourceInstructionImages
        self.sourceScrapeStatus = sourceScrapeStatus
        self.sourceScrapeError = sourceScrapeError
        self.coverFileId = coverFileId
        self.partsCount = partsCount
        self.totalFileCount = totalFileCount
        self.imageCount = imageCount
        self.hasManualEstimate = hasManualEstimate
        self.shopifyProductId = shopifyProductId
        self.files = files
    }
}

/// A configured scan root (Plex-style "library") — a folder under the
/// server's generic mounted media root, added/removed from Settings.
public struct LibraryDTO: Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Relative to the server's media root — never an absolute host path.
    public var relativePath: String
    public var dateAdded: Date

    public init(id: UUID = UUID(), name: String, relativePath: String, dateAdded: Date = Date()) {
        self.id = id
        self.name = name
        self.relativePath = relativePath
        self.dateAdded = dateAdded
    }
}
