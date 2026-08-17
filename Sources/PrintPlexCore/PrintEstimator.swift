import Foundation

// MARK: - Printer Profile

public struct PrinterProfile: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var buildX: Double  // mm
    public var buildY: Double  // mm
    public var buildZ: Double  // mm
    public var perimeterSpeedMMPS: Double
    public var infillSpeedMMPS: Double
    public var nozzleDiameterMM: Double
    public var defaultLayerHeightMM: Double
    /// Overhead added to filament weight + print time for support structures (%)
    public var supportsPercent: Double
    /// Overhead added to filament weight + print time for purge tower / color changes (%)
    public var purgePercent: Double
    /// Fraction of nominal speed actually achieved (acceleration, direction changes, feature limits)
    public var speedEfficiency: Double

    public var lineWidthMM: Double { nozzleDiameterMM * 1.2 }

    public init(id: UUID, name: String, buildX: Double, buildY: Double, buildZ: Double,
                perimeterSpeedMMPS: Double, infillSpeedMMPS: Double,
                nozzleDiameterMM: Double, defaultLayerHeightMM: Double,
                supportsPercent: Double = 20, purgePercent: Double = 5,
                speedEfficiency: Double = 0.35) {
        self.id = id; self.name = name
        self.buildX = buildX; self.buildY = buildY; self.buildZ = buildZ
        self.perimeterSpeedMMPS = perimeterSpeedMMPS
        self.infillSpeedMMPS = infillSpeedMMPS
        self.nozzleDiameterMM = nozzleDiameterMM
        self.defaultLayerHeightMM = defaultLayerHeightMM
        self.supportsPercent = supportsPercent
        self.purgePercent = purgePercent
        self.speedEfficiency = speedEfficiency
    }

    // Deterministic UUIDs so the selection persists across store recreations
    public static let defaults: [PrinterProfile] = [
        PrinterProfile(
            id: UUID(uuidString: "DA7F0001-0000-0000-0000-000000000001")!,
            name: "BambuLab P1S",
            buildX: 256, buildY: 256, buildZ: 256,
            perimeterSpeedMMPS: 200, infillSpeedMMPS: 300,
            nozzleDiameterMM: 0.4, defaultLayerHeightMM: 0.2,
            supportsPercent: 20, purgePercent: 5, speedEfficiency: 0.35
        ),
        PrinterProfile(
            id: UUID(uuidString: "DA7F0001-0000-0000-0000-000000000002")!,
            name: "BambuLab A1",
            buildX: 256, buildY: 256, buildZ: 256,
            perimeterSpeedMMPS: 200, infillSpeedMMPS: 300,
            nozzleDiameterMM: 0.4, defaultLayerHeightMM: 0.2,
            supportsPercent: 20, purgePercent: 5, speedEfficiency: 0.35
        ),
        PrinterProfile(
            id: UUID(uuidString: "DA7F0001-0000-0000-0000-000000000003")!,
            name: "SnapMaker U1",
            buildX: 270, buildY: 270, buildZ: 270,
            perimeterSpeedMMPS: 200, infillSpeedMMPS: 280,
            nozzleDiameterMM: 0.4, defaultLayerHeightMM: 0.2,
            supportsPercent: 20, purgePercent: 2, speedEfficiency: 0.40
        ),
    ]
}

extension PrinterProfile: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, buildX, buildY, buildZ
        case perimeterSpeedMMPS, infillSpeedMMPS
        case nozzleDiameterMM, defaultLayerHeightMM
        case supportsPercent, purgePercent, speedEfficiency
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id   = try c.decode(UUID.self,   forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        buildX = try c.decode(Double.self, forKey: .buildX)
        buildY = try c.decode(Double.self, forKey: .buildY)
        buildZ = try c.decode(Double.self, forKey: .buildZ)
        perimeterSpeedMMPS   = try c.decode(Double.self, forKey: .perimeterSpeedMMPS)
        infillSpeedMMPS      = try c.decode(Double.self, forKey: .infillSpeedMMPS)
        nozzleDiameterMM     = try c.decode(Double.self, forKey: .nozzleDiameterMM)
        defaultLayerHeightMM = try c.decode(Double.self, forKey: .defaultLayerHeightMM)
        // New fields — fall back to sensible defaults when loading older saved data
        supportsPercent = try c.decodeIfPresent(Double.self, forKey: .supportsPercent) ?? 20.0
        purgePercent    = try c.decodeIfPresent(Double.self, forKey: .purgePercent)    ?? 5.0
        speedEfficiency = try c.decodeIfPresent(Double.self, forKey: .speedEfficiency) ?? 0.35
    }
}

// MARK: - Material

public struct PrintMaterial: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var densityGCM3: Double  // g/cm³
    public var pricePerKg: Double   // €/kg

    public init(id: UUID, name: String, densityGCM3: Double, pricePerKg: Double) {
        self.id = id
        self.name = name
        self.densityGCM3 = densityGCM3
        self.pricePerKg = pricePerKg
    }

    public static let defaults: [PrintMaterial] = [
        PrintMaterial(id: UUID(uuidString: "CAFE0001-0000-0000-0000-000000000001")!, name: "PLA",        densityGCM3: 1.24, pricePerKg: 20.0),
        PrintMaterial(id: UUID(uuidString: "CAFE0001-0000-0000-0000-000000000002")!, name: "PETG",       densityGCM3: 1.27, pricePerKg: 22.0),
        PrintMaterial(id: UUID(uuidString: "CAFE0001-0000-0000-0000-000000000003")!, name: "ABS",        densityGCM3: 1.04, pricePerKg: 20.0),
        PrintMaterial(id: UUID(uuidString: "CAFE0001-0000-0000-0000-000000000004")!, name: "ASA",        densityGCM3: 1.07, pricePerKg: 25.0),
        PrintMaterial(id: UUID(uuidString: "CAFE0001-0000-0000-0000-000000000005")!, name: "TPU",        densityGCM3: 1.20, pricePerKg: 30.0),
        PrintMaterial(id: UUID(uuidString: "CAFE0001-0000-0000-0000-000000000006")!, name: "PA (Nylon)", densityGCM3: 1.14, pricePerKg: 35.0),
        PrintMaterial(id: UUID(uuidString: "CAFE0001-0000-0000-0000-000000000007")!, name: "PC",         densityGCM3: 1.20, pricePerKg: 40.0),
    ]
}

// MARK: - Manual Work Level

public enum ManualWorkLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case aucun, easy, medium, hard
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .aucun:  return "Aucun"
        case .easy:   return "Facile"
        case .medium: return "Moyen"
        case .hard:   return "Difficile"
        }
    }

    public var cost: Double {
        switch self {
        case .aucun:  return 0.0
        case .easy:   return 5.0
        case .medium: return 10.0
        case .hard:   return 25.0
        }
    }
}

// MARK: - Print Settings

public struct PrintSettings: Codable, Sendable {
    public var layerHeightMM: Double
    public var shellCount: Int
    public var infillPercent: Int
    public var filamentDiameterMM: Double

    public init(layerHeightMM: Double = 0.2, shellCount: Int = 3,
                infillPercent: Int = 15, filamentDiameterMM: Double = 1.75) {
        self.layerHeightMM = layerHeightMM
        self.shellCount = shellCount
        self.infillPercent = infillPercent
        self.filamentDiameterMM = filamentDiameterMM
    }
}

// MARK: - Estimate result

public struct PrintEstimate: Codable, Sendable {
    public let filamentLengthM:  Double
    public let filamentWeightG:  Double
    public let printTimeSeconds: Int
    public let layerCount:       Int
    public let fitsOnBed:        Bool
    public let printerName:      String
    public let materialName:     String
    public let filamentCostEur:  Double
    public let timeCostEur:      Double
    public let manualCostEur:    Double

    public init(filamentLengthM: Double, filamentWeightG: Double, printTimeSeconds: Int,
                layerCount: Int, fitsOnBed: Bool, printerName: String, materialName: String,
                filamentCostEur: Double, timeCostEur: Double, manualCostEur: Double) {
        self.filamentLengthM = filamentLengthM
        self.filamentWeightG = filamentWeightG
        self.printTimeSeconds = printTimeSeconds
        self.layerCount = layerCount
        self.fitsOnBed = fitsOnBed
        self.printerName = printerName
        self.materialName = materialName
        self.filamentCostEur = filamentCostEur
        self.timeCostEur = timeCostEur
        self.manualCostEur = manualCostEur
    }

    public var totalCostEur: Double { filamentCostEur + timeCostEur + manualCostEur }

    public var formattedTime: String {
        let h = printTimeSeconds / 3600
        let m = (printTimeSeconds % 3600) / 60
        if h > 0 { return m > 0 ? "\(h)h \(m)min" : "\(h)h" }
        return "\(max(1, m))min"
    }
    public var formattedWeight: String { String(format: "%.0f g", filamentWeightG) }
    public var formattedLength: String { String(format: "%.1f m", filamentLengthM) }
    public var formattedTotalCost: String { String(format: "%.2f €", totalCostEur) }
}

// MARK: - Estimator

public enum PrintEstimator {

    /// Estimates filament usage and print time from parsed mesh statistics.
    ///
    /// Formula:
    ///   plastic = clamp(shell_volume, 0, mesh_volume) + core_volume × infill_ratio
    ///   shell_volume = surface_area × line_width × shell_count
    ///   print_time  = (path_length / weighted_avg_speed) × 1.30 + 300 s startup
    public static func estimate(
        parsed: ThreeMFParser.Result,
        printer: PrinterProfile,
        material: PrintMaterial,
        settings: PrintSettings = PrintSettings(),
        manualWork: ManualWorkLevel = .aucun
    ) -> PrintEstimate {
        let lineW  = printer.lineWidthMM
        let layerH = settings.layerHeightMM
        let infill = Double(settings.infillPercent) / 100.0

        let shellVol   = parsed.surfaceAreaMM2 * lineW * Double(settings.shellCount)
        let coreVol    = max(0, parsed.volumeMM3 - shellVol)
        let plasticMM3 = min(shellVol, parsed.volumeMM3) + coreVol * infill

        let crossSection  = Double.pi * pow(settings.filamentDiameterMM / 2.0, 2)
        let baseLengthM   = plasticMM3 / crossSection / 1000.0
        let baseWeightG   = (plasticMM3 / 1000.0) * material.densityGCM3

        // Z axis is build height in the 3MF spec
        let layerCount = Int((max(parsed.depthMM, 1.0) / layerH).rounded(.up))

        // Effective speed accounts for acceleration ramps, direction changes, feature speed limits.
        // speedEfficiency is the ratio of nominal→actual throughput (0.35 = 35% of nominal speed).
        let pathMM         = plasticMM3 / (lineW * layerH)
        let nominalSpeed   = printer.perimeterSpeedMMPS * 0.30 + printer.infillSpeedMMPS * 0.70
        let effectiveSpeed = nominalSpeed * printer.speedEfficiency
        let basePrintSec   = pathMM / effectiveSpeed
        // 5 s per layer for Z-hop and toolhead deceleration at each layer change
        let layerOverheadSec = Double(layerCount) * 5.0

        // Supports and purge overhead come from the printer profile (per-printer configuration)
        let overhead  = 1.0 + printer.supportsPercent / 100.0 + printer.purgePercent / 100.0
        let lengthM   = baseLengthM * overhead
        let weightG   = baseWeightG * overhead
        let totalSec  = (basePrintSec + layerOverheadSec) * overhead + 120  // 2 min fixed startup

        // Fit check: sort both dimension sets — if model can be oriented to fit, it passes
        let dims  = [parsed.widthMM, parsed.heightMM, parsed.depthMM].sorted(by: >)
        let build = [printer.buildX, printer.buildY, printer.buildZ].sorted(by: >)
        let fits  = zip(dims, build).allSatisfy { $0.0 <= $0.1 }

        let costs = cost(filamentWeightG: weightG, printTimeSeconds: Int(ceil(totalSec)),
                        material: material, manualWork: manualWork)

        return PrintEstimate(
            filamentLengthM:  lengthM,
            filamentWeightG:  weightG,
            printTimeSeconds: Int(ceil(totalSec)),
            layerCount:       layerCount,
            fitsOnBed:        fits,
            printerName:      printer.name,
            materialName:     material.name,
            filamentCostEur:  costs.filamentCostEur,
            timeCostEur:      costs.timeCostEur,
            manualCostEur:    costs.manualCostEur
        )
    }

    /// Same €/kg and €/h formulas `estimate()` uses, exposed standalone so a
    /// UI can recompute cost from real/measured values (actual print time,
    /// actual filament weight) instead of the geometry-based estimate —
    /// single source of truth for the cost rates either way.
    public static func cost(filamentWeightG: Double, printTimeSeconds: Int,
                            material: PrintMaterial, manualWork: ManualWorkLevel)
    -> (filamentCostEur: Double, timeCostEur: Double, manualCostEur: Double) {
        let filamentCost = (filamentWeightG / 1000.0) * material.pricePerKg
        let timeCost     = Double(printTimeSeconds) / 3600.0 * 2.0  // 2 €/h
        return (filamentCost, timeCost, manualWork.cost)
    }

    /// Combines per-file estimates into a project total.
    /// Time is additive (prints one after another); layers = max single part.
    public static func total(estimates: [PrintEstimate],
                             printer: PrinterProfile,
                             material: PrintMaterial) -> PrintEstimate {
        PrintEstimate(
            filamentLengthM:  estimates.reduce(0) { $0 + $1.filamentLengthM },
            filamentWeightG:  estimates.reduce(0) { $0 + $1.filamentWeightG },
            printTimeSeconds: estimates.reduce(0) { $0 + $1.printTimeSeconds },
            layerCount:       estimates.map(\.layerCount).max() ?? 0,
            fitsOnBed:        estimates.allSatisfy(\.fitsOnBed),
            printerName:      printer.name,
            materialName:     material.name,
            filamentCostEur:  estimates.reduce(0) { $0 + $1.filamentCostEur },
            timeCostEur:      estimates.reduce(0) { $0 + $1.timeCostEur },
            manualCostEur:    estimates.reduce(0) { $0 + $1.manualCostEur }
        )
    }
}
