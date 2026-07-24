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

    public init(triangles: Int, widthMM: Double, heightMM: Double, depthMM: Double,
                volumeMM3: Double, surfaceAreaMM2: Double = 0, vertexCount: Int = 0,
                parsedAt: Date? = nil, plateCount: Int = 1) {
        self.triangles = triangles
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.depthMM = depthMM
        self.volumeMM3 = volumeMM3
        self.surfaceAreaMM2 = surfaceAreaMM2
        self.vertexCount = vertexCount
        self.parsedAt = parsedAt
        self.plateCount = plateCount
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
                  plateCount: result.plateCount)
    }
}

public struct PrintParamsDTO: Codable, Sendable, Equatable {
    public var layerHeightMM: Double?
    public var nozzleTempC: Int?
    public var bedTempC: Int?
    public var material: String?
    public var estimatedTimeSec: Int?
    public var manualWorkLevel: String?

    public init(layerHeightMM: Double? = nil, nozzleTempC: Int? = nil, bedTempC: Int? = nil,
                material: String? = nil, estimatedTimeSec: Int? = nil, manualWorkLevel: String? = nil) {
        self.layerHeightMM = layerHeightMM
        self.nozzleTempC = nozzleTempC
        self.bedTempC = bedTempC
        self.material = material
        self.estimatedTimeSec = estimatedTimeSec
        self.manualWorkLevel = manualWorkLevel
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
    public var printParams: PrintParamsDTO?

    public init(id: UUID = UUID(), path: String, fileName: String, fileExtension: String,
                fileSize: Int64, createdAt: Date, modifiedAt: Date, contentHash: String? = nil,
                kind: FileKind, fileRole: FileRole = .other, tags: [String] = [],
                cloudStatus: CloudStatus = .local, sourceApp: String? = nil,
                meshStats: MeshStatsDTO? = nil, printParams: PrintParamsDTO? = nil) {
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
        self.printParams = printParams
    }
}

public struct ProjectDTO: Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var folderPath: String
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

    /// Shopify integration — explicit product ID override (nil = auto-match by name)
    public var shopifyProductId: String?

    /// Populated on detail endpoints; nil on list endpoints.
    public var files: [FileDTO]?

    public init(id: UUID = UUID(), name: String, folderPath: String,
                lastModifiedAt: Date = Date(), dateAdded: Date = Date(),
                coverImageFileName: String? = nil, projectDescription: String? = nil,
                category: String? = nil, creator: String? = nil, tags: [String] = [],
                suggestedMaterials: [String] = [], multiColor: Bool? = nil,
                notes: String? = nil, shopifyProductId: String? = nil,
                files: [FileDTO]? = nil) {
        self.id = id
        self.name = name
        self.folderPath = folderPath
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
        self.shopifyProductId = shopifyProductId
        self.files = files
    }
}
