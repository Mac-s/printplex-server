import XCTest
@testable import PrintPlexCore

final class ShopifyClientTests: XCTestCase {

    func testNormalizedDomain() {
        XCTAssertEqual(
            ShopifyCredentials(storeDomain: "https://maboutique.myshopify.com/", accessToken: "t")
                .normalizedDomain,
            "maboutique.myshopify.com"
        )
        XCTAssertEqual(
            ShopifyCredentials(storeDomain: "maboutique", accessToken: "t").normalizedDomain,
            "maboutique.myshopify.com"
        )
        XCTAssertEqual(
            ShopifyCredentials(storeDomain: "  boutique.example.com  ", accessToken: "t")
                .normalizedDomain,
            "boutique.example.com"
        )
    }

    func testIsConfigured() {
        XCTAssertFalse(ShopifyCredentials(storeDomain: "", accessToken: "").isConfigured)
        XCTAssertFalse(ShopifyCredentials(storeDomain: "shop", accessToken: "  ").isConfigured)
        XCTAssertTrue(ShopifyCredentials(storeDomain: "shop", accessToken: "token").isConfigured)
    }

    func testParseLinkHeader() {
        let header = #"<https://x.myshopify.com/admin/api/2024-01/products.json?page_info=abc123&limit=250>; rel="next", <https://x.myshopify.com/admin/api/2024-01/products.json?page_info=zzz>; rel="previous""#
        XCTAssertEqual(ShopifyClient.parseLinkHeader(header), "abc123")
        XCTAssertNil(ShopifyClient.parseLinkHeader(nil))
        XCTAssertNil(ShopifyClient.parseLinkHeader(#"<https://x/p.json?page_info=zzz>; rel="previous""#))
    }

    func testMatchProductExplicitIdWins() {
        let products = [
            ShopifyProduct(id: 1, title: "Dragon articulé", status: "active", handle: "dragon",
                           variants: [ShopifyVariant(id: 10, price: "15.00", title: "Default")]),
            ShopifyProduct(id: 2, title: "Vase spirale", status: "draft", handle: "vase",
                           variants: []),
        ]

        // Explicit ID beats name matching
        let explicit = ShopifyClient.matchProduct(
            in: products, projectName: "Dragon", explicitProductId: "2")
        XCTAssertEqual(explicit?.id, 2)

        // Fuzzy name match
        let fuzzy = ShopifyClient.matchProduct(
            in: products, projectName: "dragon", explicitProductId: nil)
        XCTAssertEqual(fuzzy?.id, 1)

        // No match
        XCTAssertNil(ShopifyClient.matchProduct(
            in: products, projectName: "Inexistant", explicitProductId: nil))
    }

    func testDecodesExtendedProductFields() throws {
        let json = """
        {
            "id": 42,
            "title": "Casque Power Ranger Rouge",
            "status": "active",
            "handle": "casque-power-ranger-rouge",
            "body_html": "<p>Casque imprimé en 3D.</p>",
            "tags": "power-ranger, casque, cosplay",
            "product_type": "Accessoire cosplay",
            "vendor": "PrintPlex",
            "variants": [{"id": 1, "price": "45.00", "title": "Default"}]
        }
        """
        let product = try JSONDecoder().decode(ShopifyProduct.self, from: Data(json.utf8))

        XCTAssertEqual(product.bodyHtml, "<p>Casque imprimé en 3D.</p>")
        XCTAssertEqual(product.tagList, ["power-ranger", "casque", "cosplay"])
        XCTAssertEqual(product.productType, "Accessoire cosplay")
        XCTAssertEqual(product.vendor, "PrintPlex")
        XCTAssertEqual(product.metafields, []) // never present on products.json responses
    }

    func testMissingOptionalFieldsDefaultGracefully() throws {
        // Minimal response (e.g. a narrower `fields=`) shouldn't fail to decode.
        let json = """
        {"id": 1, "title": "T", "status": "draft", "handle": "t", "variants": []}
        """
        let product = try JSONDecoder().decode(ShopifyProduct.self, from: Data(json.utf8))
        XCTAssertNil(product.bodyHtml)
        XCTAssertEqual(product.tagList, [])
        XCTAssertNil(product.productType)
        XCTAssertNil(product.vendor)
    }

    func testDecodesMetafieldsResponse() throws {
        let json = """
        {"metafields": [
            {"id": 1, "namespace": "custom", "key": "materiau", "value": "PLA", "type": "single_line_text_field"},
            {"id": 2, "namespace": "custom", "key": "temps_impression_h", "value": "6", "type": "number_integer"}
        ]}
        """
        struct Wrapper: Codable { let metafields: [ShopifyMetafield] }
        let decoded = try JSONDecoder().decode(Wrapper.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.metafields.count, 2)
        XCTAssertEqual(decoded.metafields[0].key, "materiau")
        XCTAssertEqual(decoded.metafields[0].value, "PLA")
        XCTAssertEqual(decoded.metafields[1].type, "number_integer")
    }

    func testLowestPriceAndStatus() {
        let product = ShopifyProduct(
            id: 1, title: "T", status: "active", handle: "t",
            variants: [
                ShopifyVariant(id: 1, price: "25.00", title: "Grand"),
                ShopifyVariant(id: 2, price: "12.50", title: "Petit"),
            ])
        XCTAssertEqual(product.lowestPrice, 12.50)
        XCTAssertTrue(product.isActive)
        XCTAssertEqual(product.statusLabel, "En vente")
    }
}
