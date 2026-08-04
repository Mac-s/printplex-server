import Foundation

// MARK: - iCloud Download Status

public enum CloudStatus: String, Codable, Sendable {
    case local
    case cloudOnly
    case downloading
}

// MARK: - File Kind (3D format discrimination)

public enum FileKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case stl, threeMF, obj, step, other
    public var id: String { rawValue }

    public static func from(extension ext: String) -> FileKind {
        switch ext.lowercased() {
        case "stl": return .stl
        case "3mf": return .threeMF
        case "obj": return .obj
        case "step", "stp": return .step
        default: return .other
        }
    }
}

// MARK: - File Role (purpose within a project)

public enum FileRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case modelPart
    case renderImage
    case document
    case slicerConfig
    case other

    public var id: String { rawValue }

    public static func from(extension ext: String, fileName: String = "") -> FileRole {
        // info.json is project metadata, not a slicer config
        if fileName.lowercased() == "info" && ext.lowercased() == "json" {
            return .document
        }
        switch ext.lowercased() {
        case "stl", "3mf", "obj", "step", "stp":
            return .modelPart
        case "png", "jpg", "jpeg", "webp", "bmp", "gif", "tiff", "tif", "heic":
            return .renderImage
        case "md", "txt", "pdf", "doc", "docx", "rtf":
            return .document
        case "gcode", "ini", "json", "curaprofile":
            return .slicerConfig
        default:
            return .other
        }
    }

    public var sectionTitle: String {
        switch self {
        case .modelPart: return "Pièces 3D"
        case .renderImage: return "Rendus & images"
        case .document: return "Documentation"
        case .slicerConfig: return "Configuration slicer"
        case .other: return "Autres fichiers"
        }
    }

    /// SF Symbol name — clients map this to their own icon system if needed.
    public var iconName: String {
        switch self {
        case .modelPart: return "cube.fill"
        case .renderImage: return "photo"
        case .document: return "doc.text"
        case .slicerConfig: return "gearshape.2"
        case .other: return "doc"
        }
    }
}

// MARK: - Project info.json

/// Parsed from `info.json` files placed alongside 3D models.
public struct ProjectInfo: Sendable, Codable {
    public var nom: String?
    public var description: String?
    public var categorie: String?
    public var createur: String?
    public var tags: [String]?
    public var fichiers: [String]?
    public var materiaux_suggeres: [String]?
    public var multi_couleur: Bool?
    public var notes: String?
    public var image_principale: String?
    public var shopify_product_id: String?
    public var deja_imprime: Bool?
    /// Link back to the design's page on whatever site it came from (e.g. a
    /// ForgeCore design URL) — general provenance, not tied to one source.
    public var source_url: String?
    /// Free-text hardware line items (e.g. "N52 Magnet (6 x 2mm) × 8"), as
    /// listed by the design's source — kept as plain strings rather than a
    /// structured type, matching how `tags`/`materiaux_suggeres` are stored.
    public var source_hardware: [String]?
    /// The design's own weight/print-time estimate, as stated by its source —
    /// kept as opaque strings (e.g. "1.16kg", "2d 5h 44m") since formats vary
    /// by source, and deliberately separate from PrintPlex's own computed
    /// estimate (`PrintEstimate`), which is a different, more authoritative
    /// number for *this* printer/material/file — showing both together next
    /// to each other without labels would just be confusing.
    public var source_estimated_weight: String?
    public var source_estimated_print_time: String?
    /// Filenames (relative to the project folder) of imported assembly-
    /// instruction images — kept out of `image_principale`/the regular photo
    /// gallery and cover-image selection, shown in their own section instead.
    public var source_instruction_images: [String]?

    public init(nom: String? = nil,
                description: String? = nil,
                categorie: String? = nil,
                createur: String? = nil,
                tags: [String]? = nil,
                fichiers: [String]? = nil,
                materiaux_suggeres: [String]? = nil,
                multi_couleur: Bool? = nil,
                notes: String? = nil,
                image_principale: String? = nil,
                shopify_product_id: String? = nil,
                deja_imprime: Bool? = nil,
                source_url: String? = nil,
                source_hardware: [String]? = nil,
                source_estimated_weight: String? = nil,
                source_estimated_print_time: String? = nil,
                source_instruction_images: [String]? = nil) {
        self.nom = nom
        self.description = description
        self.categorie = categorie
        self.createur = createur
        self.tags = tags
        self.fichiers = fichiers
        self.materiaux_suggeres = materiaux_suggeres
        self.multi_couleur = multi_couleur
        self.notes = notes
        self.image_principale = image_principale
        self.shopify_product_id = shopify_product_id
        self.deja_imprime = deja_imprime
        self.source_url = source_url
        self.source_hardware = source_hardware
        self.source_estimated_weight = source_estimated_weight
        self.source_estimated_print_time = source_estimated_print_time
        self.source_instruction_images = source_instruction_images
    }
}

// MARK: - Scan Value Types

public struct ScannedFile: Sendable {
    public let path: String
    public let fileName: String
    public let fileExtension: String
    public let fileSize: Int64
    public let createdAt: Date
    public let modifiedAt: Date
    public let contentHash: String?
    public let kind: FileKind
    public let cloudStatus: CloudStatus
    public let fileRole: FileRole

    public init(path: String, fileName: String, fileExtension: String,
                fileSize: Int64, createdAt: Date, modifiedAt: Date,
                contentHash: String?, kind: FileKind,
                cloudStatus: CloudStatus, fileRole: FileRole) {
        self.path = path
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.fileSize = fileSize
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.contentHash = contentHash
        self.kind = kind
        self.cloudStatus = cloudStatus
        self.fileRole = fileRole
    }
}

public struct ScannedProject: Sendable {
    public let name: String
    public let folderPath: String
    public let info: ProjectInfo?

    public init(name: String, folderPath: String, info: ProjectInfo?) {
        self.name = name
        self.folderPath = folderPath
        self.info = info
    }
}

public enum ScanEvent: Sendable {
    case projectDiscovered(ScannedProject, isNew: Bool)
    case fileScanned(ScannedFile, projectPath: String, isNew: Bool, isUnchanged: Bool)
    case unsortedFileScanned(ScannedFile, isNew: Bool, isUnchanged: Bool)
    case projectComplete(projectPath: String)
}
