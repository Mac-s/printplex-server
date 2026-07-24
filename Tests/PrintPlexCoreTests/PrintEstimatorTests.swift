import XCTest
@testable import PrintPlexCore

final class PrintEstimatorTests: XCTestCase {

    private var cubeResult: ThreeMFParser.Result {
        ThreeMFParser.Result(
            volumeMM3: 1000, surfaceAreaMM2: 600,
            widthMM: 10, heightMM: 10, depthMM: 10,
            triangleCount: 12, vertexCount: 8, plateCount: 1
        )
    }

    func testEstimateCubeOnDefaultPrinter() {
        let printer = PrinterProfile.defaults[0]   // BambuLab P1S
        let pla = PrintMaterial.defaults[0]        // PLA

        let estimate = PrintEstimator.estimate(parsed: cubeResult, printer: printer, material: pla)

        XCTAssertTrue(estimate.fitsOnBed)
        XCTAssertEqual(estimate.layerCount, 50)    // 10 mm / 0.2 mm
        XCTAssertGreaterThan(estimate.filamentWeightG, 0)
        XCTAssertGreaterThan(estimate.filamentLengthM, 0)
        XCTAssertGreaterThan(estimate.printTimeSeconds, 120)  // at least the fixed startup
        XCTAssertGreaterThan(estimate.totalCostEur, 0)
        XCTAssertEqual(estimate.printerName, "BambuLab P1S")
        XCTAssertEqual(estimate.materialName, "PLA")
    }

    func testOversizedModelDoesNotFit() {
        let big = ThreeMFParser.Result(
            volumeMM3: 1_000_000, surfaceAreaMM2: 60_000,
            widthMM: 300, heightMM: 300, depthMM: 300,
            triangleCount: 12, vertexCount: 8, plateCount: 1
        )
        let estimate = PrintEstimator.estimate(
            parsed: big, printer: PrinterProfile.defaults[0], material: PrintMaterial.defaults[0]
        )
        XCTAssertFalse(estimate.fitsOnBed)
    }

    func testRotatedFitIsAccepted() {
        // 250×100×260: taller than wide, but reorientable inside 256³
        let model = ThreeMFParser.Result(
            volumeMM3: 1000, surfaceAreaMM2: 600,
            widthMM: 250, heightMM: 100, depthMM: 260,
            triangleCount: 12, vertexCount: 8, plateCount: 1
        )
        let estimate = PrintEstimator.estimate(
            parsed: model, printer: PrinterProfile.defaults[2], material: PrintMaterial.defaults[0]
        )
        // SnapMaker U1 is 270³ — sorted dims fit sorted build volume
        XCTAssertTrue(estimate.fitsOnBed)
    }

    func testTotalAggregation() {
        let printer = PrinterProfile.defaults[0]
        let pla = PrintMaterial.defaults[0]
        let e1 = PrintEstimator.estimate(parsed: cubeResult, printer: printer, material: pla)
        let e2 = PrintEstimator.estimate(parsed: cubeResult, printer: printer, material: pla,
                                         manualWork: .medium)

        let total = PrintEstimator.total(estimates: [e1, e2], printer: printer, material: pla)

        XCTAssertEqual(total.filamentWeightG, e1.filamentWeightG + e2.filamentWeightG, accuracy: 0.001)
        XCTAssertEqual(total.printTimeSeconds, e1.printTimeSeconds + e2.printTimeSeconds)
        XCTAssertEqual(total.layerCount, 50)             // max, not sum
        XCTAssertEqual(total.manualCostEur, 10.0)        // only e2 has manual work
        XCTAssertTrue(total.fitsOnBed)
    }

    func testManualWorkCosts() {
        XCTAssertEqual(ManualWorkLevel.aucun.cost, 0)
        XCTAssertEqual(ManualWorkLevel.easy.cost, 5)
        XCTAssertEqual(ManualWorkLevel.medium.cost, 10)
        XCTAssertEqual(ManualWorkLevel.hard.cost, 25)
    }

    func testPrinterProfileDecodingWithMissingNewFields() throws {
        // Older saved payloads lack supportsPercent/purgePercent/speedEfficiency
        let json = """
        {"id":"DA7F0001-0000-0000-0000-000000000001","name":"Old","buildX":200,"buildY":200,
         "buildZ":200,"perimeterSpeedMMPS":100,"infillSpeedMMPS":150,
         "nozzleDiameterMM":0.4,"defaultLayerHeightMM":0.2}
        """
        let profile = try JSONDecoder().decode(PrinterProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.supportsPercent, 20.0)
        XCTAssertEqual(profile.purgePercent, 5.0)
        XCTAssertEqual(profile.speedEfficiency, 0.35)
    }
}
