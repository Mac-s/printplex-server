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
            "variants": [
                {"id": 1, "price": "45.00", "title": "Petit", "sku": "CASQUE-RG-P",
                 "option1": "Petit", "compare_at_price": "55.00"},
                {"id": 2, "price": "50.00", "title": "Grand", "sku": "CASQUE-RG-G", "option1": "Grand"}
            ],
            "images": [
                {"id": 100, "src": "https://cdn.shopify.com/img/rouge-1.jpg", "alt": "Casque rouge, vue de face"},
                {"id": 101, "src": "https://cdn.shopify.com/img/rouge-2.jpg"}
            ]
        }
        """
        let product = try JSONDecoder().decode(ShopifyProduct.self, from: Data(json.utf8))

        XCTAssertEqual(product.bodyHtml, "<p>Casque imprimé en 3D.</p>")
        XCTAssertEqual(product.tagList, ["power-ranger", "casque", "cosplay"])
        XCTAssertEqual(product.productType, "Accessoire cosplay")
        XCTAssertEqual(product.vendor, "PrintPlex")
        XCTAssertEqual(product.metafields, []) // never present on products.json responses

        XCTAssertEqual(product.variants[0].sku, "CASQUE-RG-P")
        XCTAssertEqual(product.variants[0].option1, "Petit")
        XCTAssertEqual(product.variants[0].compareAtPrice, "55.00")
        XCTAssertNil(product.variants[1].compareAtPrice)

        XCTAssertEqual(product.images.count, 2)
        XCTAssertEqual(product.images[0].src, "https://cdn.shopify.com/img/rouge-1.jpg")
        XCTAssertEqual(product.images[0].alt, "Casque rouge, vue de face")
        XCTAssertNil(product.images[1].alt)
    }

    /// The bug this guards against: decoding Shopify's raw (snake_case)
    /// response worked fine, and re-encoding our own already-decoded struct
    /// round-tripped fine too (see `testProductEncodesAndDecodesRoundTrip`) —
    /// but the *encoder* was reusing the *decoder*'s snake_case keys, so the
    /// JSON this server actually sends to the dashboard still had
    /// `body_html`/`product_type` instead of `bodyHtml`/`productType`, which
    /// the JS reads. Only decoding Shopify's real shape and inspecting what
    /// comes back *out* the other side catches that; a plain encode-then-
    /// decode round trip (using the same keys both ways) can't.
    func testDecodedProductReEncodesWithCamelCaseKeysForOurOwnAPI() throws {
        let shopifyShapedJSON = """
        {
            "id": 1, "title": "T", "status": "active", "handle": "t",
            "body_html": "<p>desc</p>", "product_type": "Cosplay",
            "variants": [{"id": 1, "price": "10.00", "title": "Default",
                          "compare_at_price": "15.00"}]
        }
        """
        let product = try JSONDecoder().decode(ShopifyProduct.self, from: Data(shopifyShapedJSON.utf8))

        let reEncoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(product)) as? [String: Any]

        XCTAssertEqual(reEncoded?["bodyHtml"] as? String, "<p>desc</p>")
        XCTAssertEqual(reEncoded?["productType"] as? String, "Cosplay")
        XCTAssertNil(reEncoded?["body_html"])
        XCTAssertNil(reEncoded?["product_type"])

        let variants = reEncoded?["variants"] as? [[String: Any]]
        XCTAssertEqual(variants?.first?["compareAtPrice"] as? String, "15.00")
        XCTAssertNil(variants?.first?["compare_at_price"])
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
        XCTAssertEqual(product.images, [])
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
