import XCTVapor
import PrintPlexCore
@testable import PrintPlexServerApp

/// Covers the settings API backing the web dashboard's "Réglages" menu:
/// printers/materials CRUD, scan settings, and Shopify credentials.
final class SettingsTests: XCTestCase {
    var app: Application!
    var mediaDir: URL!
    var dataDir: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
        mediaDir = base.appendingPathComponent("printplex-settings-media-\(UUID().uuidString)")
        dataDir = base.appendingPathComponent("printplex-settings-data-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        setenv("PRINTPLEX_MEDIA_PATH", mediaDir.path, 1)
        setenv("PRINTPLEX_DATA_PATH", dataDir.path, 1)
        setenv("PRINTPLEX_DB_IN_MEMORY", "1", 1)
        setenv("PRINTPLEX_SCAN_INTERVAL_MIN", "0", 1)
        setenv("SHOPIFY_STORE_DOMAIN", "", 1)
        setenv("SHOPIFY_ACCESS_TOKEN", "", 1)

        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
        try? FileManager.default.removeItem(at: mediaDir)
        try? FileManager.default.removeItem(at: dataDir)
    }

    // MARK: - Printers

    func testPrintersAreSeededFromDefaults() async throws {
        try await app.test(.GET, "api/printers") { res async throws in
            XCTAssertEqual(res.status, .ok)
            let printers = try res.content.decode([PrinterProfile].self)
            XCTAssertEqual(printers.count, 3)
            XCTAssertEqual(printers.first?.name, "BambuLab P1S")
        }
    }

    func testCreateUpdateDeletePrinter() async throws {
        var newID: UUID?
        try await app.test(.POST, "api/printers", beforeRequest: { req in
            try req.content.encode(PrinterUpsertRequest(
                name: "Prusa MK4", buildX: 250, buildY: 210, buildZ: 220,
                perimeterSpeedMMPS: 150, infillSpeedMMPS: 200,
                nozzleDiameterMM: 0.4, defaultLayerHeightMM: 0.2,
                supportsPercent: 15, purgePercent: 3, speedEfficiency: 0.4
            ))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let printer = try res.content.decode(PrinterProfile.self)
            XCTAssertEqual(printer.name, "Prusa MK4")
            newID = printer.id
        })
        let id = try XCTUnwrap(newID)

        // Now 4 printers total, new one appended last (sortOrder)
        try await app.test(.GET, "api/printers") { res async throws in
            let printers = try res.content.decode([PrinterProfile].self)
            XCTAssertEqual(printers.count, 4)
            XCTAssertEqual(printers.last?.name, "Prusa MK4")
        }

        // Partial update
        try await app.test(.PATCH, "api/printers/\(id)", beforeRequest: { req in
            try req.content.encode(PrinterUpdateRequest(speedEfficiency: 0.5))
        }, afterResponse: { res async throws in
            let printer = try res.content.decode(PrinterProfile.self)
            XCTAssertEqual(printer.speedEfficiency, 0.5)
            XCTAssertEqual(printer.name, "Prusa MK4") // untouched fields preserved
        })

        // Delete
        try await app.test(.DELETE, "api/printers/\(id)") { res async in
            XCTAssertEqual(res.status, .noContent)
        }
        try await app.test(.GET, "api/printers") { res async throws in
            let printers = try res.content.decode([PrinterProfile].self)
            XCTAssertEqual(printers.count, 3)
        }
    }

    func testDeleteUnknownPrinterReturns404() async throws {
        try await app.test(.DELETE, "api/printers/\(UUID())") { res async in
            XCTAssertEqual(res.status, .notFound)
        }
    }

    // MARK: - Materials

    func testMaterialsAreSeededFromDefaults() async throws {
        try await app.test(.GET, "api/materials") { res async throws in
            let materials = try res.content.decode([PrintMaterial].self)
            XCTAssertEqual(materials.count, 7)
            XCTAssertEqual(materials.first?.name, "PLA")
        }
    }

    func testUpdateMaterialPrice() async throws {
        var plaID: UUID?
        try await app.test(.GET, "api/materials") { res async throws in
            plaID = try res.content.decode([PrintMaterial].self).first?.id
        }
        let id = try XCTUnwrap(plaID)

        try await app.test(.PATCH, "api/materials/\(id)", beforeRequest: { req in
            try req.content.encode(MaterialUpdateRequest(pricePerKg: 27.5))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let material = try res.content.decode(PrintMaterial.self)
            XCTAssertEqual(material.pricePerKg, 27.5)
            XCTAssertEqual(material.name, "PLA")
        })

        // Rejects non-positive prices
        try await app.test(.PATCH, "api/materials/\(id)", beforeRequest: { req in
            try req.content.encode(MaterialUpdateRequest(pricePerKg: -1))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    // MARK: - Scan settings

    func testScanSettingsDefaultsAndUpdate() async throws {
        try await app.test(.GET, "api/settings") { res async throws in
            XCTAssertEqual(res.status, .ok)
            let overview = try res.content.decode(SettingsOverview.self)
            // PRINTPLEX_SCAN_INTERVAL_MIN=0 in tests → seeded as disabled
            XCTAssertFalse(overview.autoScanEnabled)
            XCTAssertEqual(overview.scanIntervalMinutes, 15)
            XCTAssertFalse(overview.shopifyConfigured)
        }

        try await app.test(.PATCH, "api/settings/scan", beforeRequest: { req in
            try req.content.encode(ScanSettingsUpdateRequest(autoScanEnabled: true, scanIntervalMinutes: 45))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let settings = try res.content.decode(ScanSettings.self)
            XCTAssertTrue(settings.autoScanEnabled)
            XCTAssertEqual(settings.scanIntervalMinutes, 45)
        })

        // Persisted — reflected in the overview too
        try await app.test(.GET, "api/settings") { res async throws in
            let overview = try res.content.decode(SettingsOverview.self)
            XCTAssertTrue(overview.autoScanEnabled)
            XCTAssertEqual(overview.scanIntervalMinutes, 45)
        }

        // Partial update only touches the given field
        try await app.test(.PATCH, "api/settings/scan", beforeRequest: { req in
            try req.content.encode(ScanSettingsUpdateRequest(autoScanEnabled: false, scanIntervalMinutes: nil))
        }, afterResponse: { res async throws in
            let settings = try res.content.decode(ScanSettings.self)
            XCTAssertFalse(settings.autoScanEnabled)
            XCTAssertEqual(settings.scanIntervalMinutes, 45) // untouched
        })
    }

    // MARK: - Shopify settings

    func testShopifySettingsRoundTrip() async throws {
        try await app.test(.GET, "api/settings/shopify") { res async throws in
            let shopify = try res.content.decode(ShopifySettingsResponse.self)
            XCTAssertFalse(shopify.configured)
            XCTAssertEqual(shopify.storeDomain, "")
        }

        try await app.test(.PUT, "api/settings/shopify", beforeRequest: { req in
            try req.content.encode(ShopifySettingsUpdateRequest(
                storeDomain: "ma-boutique.myshopify.com", accessToken: "shpat_test123"))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let shopify = try res.content.decode(ShopifySettingsResponse.self)
            XCTAssertTrue(shopify.configured)
            XCTAssertEqual(shopify.storeDomain, "ma-boutique.myshopify.com")
        })

        // Prefill works after saving
        try await app.test(.GET, "api/settings/shopify") { res async throws in
            let shopify = try res.content.decode(ShopifySettingsResponse.self)
            XCTAssertEqual(shopify.accessToken, "shpat_test123")
        }

        // Now reflected in the general overview, and shopify/products no
        // longer 503s (it'll fail on the actual HTTP call to a fake domain,
        // but that's a 5xx from the sync, not "not configured").
        try await app.test(.GET, "api/settings") { res async throws in
            let overview = try res.content.decode(SettingsOverview.self)
            XCTAssertTrue(overview.shopifyConfigured)
            XCTAssertEqual(overview.shopifyStoreDomain, "ma-boutique.myshopify.com")
        }
    }
}
